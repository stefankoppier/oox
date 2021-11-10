module Execution.Semantics(
      execAssert
    , execAssume
    , execReturn
    , execInvocation
    , execFork
    , execMemberEntry
    , execMemberExit
    , execException
    , execTryEntry
    , execTryExit
    , execCatchEntry
    , execDeclare
    , execLock
    , execUnlock
    , execAssign
) where

import Debug.Trace
import qualified GHC.Stack as GHC
import qualified Data.Set as S
import qualified Data.Map as M
import           Data.Maybe
import           Control.Lens ((&), (^?!), (^.), (%~), (.~), (<>~))
import           Text.Pretty
import           Data.Configuration
import           Data.Statistics
import           Data.Positioned
import           Analysis.Type.Typeable
import           Analysis.CFA.CFG
import           Analysis.SymbolTable
import           Language.Syntax
import           Language.Syntax.DSL
import qualified Language.Syntax.Lenses as SL
import           Execution.Semantics.Evaluation
import           Execution.Semantics.Thread
import           Execution.Semantics.Exception
import           Execution.Semantics.Concretization
import           Execution.Semantics.StackFrame
import           Execution.Semantics.Heap
import           Execution.Semantics.Process
import           Execution.Semantics.AssertAssume
import           Execution.Semantics.Assignment
import           Execution.Effects
import           Execution.Errors
import           Execution.State
import           Execution.State.Thread
import           Execution.State.Heap
import           Execution.State.PathConstraints as PathConstraints
import           Execution.State.LockSet as LockSet
import           Execution.Verification

{-
execAssert :: GHC.HasCallStack => ExecutionState -> Expression -> Engine r ExecutionState
>>> moved to module AssertAssume
-}
execAssertEnsures :: GHC.HasCallStack => ExecutionState -> Engine r ExecutionState
execAssertEnsures state = do
    config <- askConfig
    if verifyRequires config
        then
            case getCurrentThread state of
                Just thread -> do
                    let frame   = fromJust (getLastStackFrame thread)
                    let ensures = frame ^. currentMember ^?! SL.specification ^?! SL.ensures
                    maybe (return state) (execAssert state) ensures
                Nothing ->
                    stop state cannotGetCurrentThreadErrorMessage
        else
            return state

execAssertRequires :: GHC.HasCallStack => ExecutionState -> Engine r ExecutionState
execAssertRequires state = do
    config <- askConfig
    if verifyRequires config
        then
            case getCurrentThread state of
                Just thread -> do
                    let frame    = fromJust (getLastStackFrame thread)
                    let requires = frame ^. currentMember ^?! SL.specification ^?! SL.requires
                    maybe (return state) (execAssert state) requires
                Nothing ->
                    stop state cannotGetCurrentThreadErrorMessage
        else
            return state

execAssertExceptional :: GHC.HasCallStack => ExecutionState -> Engine r ExecutionState
execAssertExceptional state = do
    config <- askConfig
    if verifyExceptional config
        then
            case getCurrentThread state of
                Just thread -> do
                    let frame       = fromJust (getLastStackFrame thread)
                    let exceptional = frame ^. currentMember ^?! SL.specification ^?! SL.exceptional
                    maybe (return state) (execAssert state) exceptional
                Nothing     ->
                    stop state cannotGetCurrentThreadErrorMessage
        else
            return state

{-
execAssume :: GHC.HasCallStack => ExecutionState -> Expression -> Engine r ExecutionState
>>> moved to module AssertAssume
-}

execInvocation :: GHC.HasCallStack => ExecutionState -> Invocation -> Maybe Lhs -> Node -> Engine r (ExecutionState, Node)
execInvocation state0 invocation lhs neighbour
    | Just (declaration, member) <- invocation ^. SL.resolved = do
        let arguments = invocation ^. SL.arguments
        (state1, concretizations) <- concretesOfTypes state0 ARRAYRuntimeType arguments
        concretizeWithResult concretizations state1 $ \ state2 ->
            case member of
                Method True _ _ _ _ _ labels _-> do
                    state3 <- execStaticMethod state2 member arguments lhs neighbour
                    return (state3, fst labels)
                Method False _ _ _ _ _ labels _ -> do
                    let thisTy = ReferenceType (declaration ^. SL.name) unknownPos
                    let this   = (thisTy, invocation ^?! SL.lhs)
                    state3 <- execMethod state2 member arguments lhs neighbour this
                    return (state3, fst labels)
                Constructor _ _ _ _ labels _ -> do
                    state3 <- execConstructor state2 member arguments lhs neighbour
                    return (state3, fst labels)
                Field _ name _ ->
                    stop state2 (expectedMethodMemberErrorMessage name)
    | otherwise =
        stop state0 unresolvedErrorMessage

execStaticMethod :: GHC.HasCallStack => ExecutionState -> DeclarationMember -> [Expression] -> Maybe Lhs -> Node -> Engine r ExecutionState
execStaticMethod state method arguments lhs neighbour = do
    let parameters = method ^?! SL.params
    pushStackFrameOnCurrentThread state neighbour method lhs (zip parameters arguments)

execMethod :: GHC.HasCallStack => ExecutionState -> DeclarationMember -> [Expression] -> Maybe Lhs -> Node -> (NonVoidType, Identifier) -> Engine r ExecutionState
execMethod state method arguments lhs neighbour this = do
    -- Construct the parameters and arguments, with 'this' as an implicit parameter.
    let parameters' = parameter' (fst this) this' : method ^?! SL.params
    let arguments'  = var' (snd this) (typeOf (fst this)) : arguments
    -- Push a new stack frame.
    pushStackFrameOnCurrentThread state neighbour method lhs (zip parameters' arguments')

execConstructor :: GHC.HasCallStack => ExecutionState -> DeclarationMember -> [Expression] -> Maybe Lhs -> Node -> Engine r ExecutionState
execConstructor state0 constructor arguments lhs neighbour  = do
    -- Construct the parameters, with 'this' as an implicit parameter.
    let className  = constructor ^?! SL.name
    let parameters = parameter' (refType' className) this' : constructor ^?! SL.params
    -- Allocate a new reference initialized with concrete default values.
    fields <- map getMember . S.toList . getAllFields className <$> askTable
    let structure = ObjectValue ((M.fromList . map (\ Field{..} -> (_name, defaultValue _ty))) fields) (typeOf constructor)
    (state1, ref) <- allocate state0 structure
    let arguments' = ref : arguments
    -- Push a new stack frame.
    pushStackFrameOnCurrentThread state1 neighbour constructor lhs (zip parameters arguments')

execFork :: GHC.HasCallStack => ExecutionState -> DeclarationMember -> [Expression] -> Engine r (ExecutionState, ThreadId)
execFork state member arguments
    | Just parent <- state ^. currentThreadId =
        spawn state parent member arguments
    | otherwise =
        stop state cannotGetCurrentThreadErrorMessage

execMemberEntry :: GHC.HasCallStack => ExecutionState -> Engine r ExecutionState
execMemberEntry state =
    -- Verify the pre condition if this is the first call.
    case state ^. programTrace of
        [] -> return state
        _  -> execAssertRequires state

execMemberExit :: GHC.HasCallStack => ExecutionState -> RuntimeType -> Engine r (ExecutionState, Maybe ((), Node))
execMemberExit state0 returnTy = do
    -- Verify the post-condition
    state1 <- execAssertEnsures state0
    if isLastStackFrame state1
        -- Despawn if this is the last stack frame to be popped
        then do
            state2 <- despawnCurrentThread state1
            return (state2, Nothing)
        -- Otherwise pop the stack frame with a copied return value.
        else
            case getCurrentThread state1 of
                Nothing ->
                    stop state1 cannotGetCurrentThreadErrorMessage
                Just thread1 -> do
                    let oldFrame  = fromJust (getLastStackFrame thread1)
                    let neighbour = Just ((), oldFrame ^. returnPoint)
                    state2 <- popStackFrame state1
                    -- Check if we need te assign the return value to some target
                    case oldFrame ^. target of
                        Just lhs -> do
                            retval <- readDeclaration state1 retval'
                            state3 <- writeDeclaration state2 retval' retval
                            let rhs = rhsExpr' (var' retval' returnTy)
                            (, neighbour) <$> execAssign state3 lhs rhs
                        Nothing  ->
                            -- No assignment to be done, continue the execution.
                            return (state2, neighbour)

execReturn :: GHC.HasCallStack => ExecutionState -> Maybe Expression -> Engine r ExecutionState
execReturn state Nothing =
    return state

execReturn state0 (Just expression) = do
    (state1, concretizations) <- concretesOfType state0 ARRAYRuntimeType expression
    concretize concretizations state1 $ \ state2 -> do
        (state3, retval) <- evaluate state2 expression
        writeDeclaration state3 retval' retval

execException :: GHC.HasCallStack => ExecutionState -> Engine r (ExecutionState, Maybe ((), Node))
execException state0
    -- Within a try block.
    | Just (handler, pops) <- findLastHandler state0 = do
        debug ("Handling an exception with '" ++ show pops ++ "' left")
        case pops of
            -- With no more stack frames to pop.
            0 ->
                return (state0, Just ((), handler))
            -- With some stack frames left to pop
            _ -> do
                state1 <- execAssertExceptional state0
                state2 <- popStackFrame state1
                execException state2
    -- Not within a try block.
    | otherwise = do
        state1 <- execAssertExceptional state0
        if isLastStackFrame state1
            then
                finish state1
            else do
                state2 <- popStackFrame state1
                execException state2

execTryEntry :: GHC.HasCallStack => ExecutionState -> Node -> Engine r ExecutionState
execTryEntry = insertHandler

execTryExit :: GHC.HasCallStack => ExecutionState -> Engine r ExecutionState
execTryExit = removeLastHandler

execCatchEntry :: GHC.HasCallStack => ExecutionState -> Engine r ExecutionState
execCatchEntry = removeLastHandler

execDeclare :: GHC.HasCallStack => ExecutionState -> NonVoidType -> Identifier -> Engine r ExecutionState
execDeclare state0 ty var = do
    let value = defaultValue ty
    writeDeclaration state0 var value

execLock :: GHC.HasCallStack => ExecutionState -> Identifier -> Engine r ExecutionState
execLock state0 var = do
    ref <- readDeclaration state0 var
    case ref of
        Lit NullLit{} _ _ -> infeasible
        SymbolicRef{}     -> do
            -- if ref is a symbolic-ref of type array, concretize it:
            --debug (">>> trying to concretize " ++ show ref)
            (state1, concretizations1) <- concretesOfType state0 ARRAYRuntimeType ref
            (state2, concretizations2) <- concretesOfType state1 REFRuntimeType ref
            --debug (">>> done concretizing " ++ show ref)
            --ref2 <- readDeclaration state0 var
            --debug (">>> new ref: " ++ show ref2)
            concretize (concretizations1 ++ concretizations2) state2 $ \ state3 ->
                execLock state3 var
        Ref ref _ _ ->
            case state0 ^. currentThreadId of
                Just currentTid ->
                    case LockSet.lookup ref (state0 ^. locks) of
                        Just tid
                            | tid == currentTid -> return state0
                            | otherwise -> infeasible
                        Nothing ->
                            return $ state0 & (locks %~ LockSet.insert ref currentTid)
                Nothing ->
                    stop state0 cannotGetCurrentThreadErrorMessage
        _ ->
            stop state0 (expectedReferenceErrorMessage ref)

execUnlock :: GHC.HasCallStack => ExecutionState -> Identifier -> Engine r ExecutionState
execUnlock state var = do
    ref <- readDeclaration state var
    case ref of
        Ref{} ->
            return $ state & (locks %~ LockSet.remove (ref ^?! SL.ref))
        _ ->
            stop state (expectedConcreteReferenceErrorMessage ref)

execAssign :: GHC.HasCallStack => ExecutionState -> Lhs -> Rhs -> Engine r ExecutionState
execAssign state0 _ RhsCall{} =
    return state0
execAssign state0 lhs rhs = do
    (state1, value) <- execRhs state0 rhs
    execLhs state1 lhs value
