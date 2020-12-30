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
import           Execution.Semantics.Assignment
import           Execution.Effects
import           Execution.Errors
import           Execution.State
import           Execution.State.Thread
import           Execution.State.Heap
import           Execution.State.PathConstraints as PathConstraints
import           Execution.State.LockSet as LockSet
import           Execution.Verification

execAssert :: ExecutionState -> Expression -> Engine r ExecutionState
execAssert state0 assertion = do
    measureVerification
    let assumptions = state0 ^. constraints
    (state1, concretizations) <- concretesOfType state0 ARRAYRuntimeType assertion
    concretize concretizations state1 $ \ state2 -> do
        let formula0 = neg' (implies' (asExpression assumptions) assertion)
        debug ("Verifying: '" ++ toString formula0 ++ "'")
        (state3, formula1) <- evaluateAsBool state2 formula0
        case formula1 of
            Right True ->
                invalid state3 assertion
            Right False ->
                return state3
            Left formula2 -> do
                _ <- verify state3 (formula2 & SL.info .~ getPos assertion)
                return state3
    
execAssertEnsures :: ExecutionState -> Engine r ExecutionState
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
                    stop state (cannotGetCurrentThreadErrorMessage "execAssertEnsures")
        else 
            return state

execAssertRequires :: ExecutionState -> Engine r ExecutionState
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
                    stop state (cannotGetCurrentThreadErrorMessage "execAssertRequires")
        else 
            return state

execAssertExceptional :: ExecutionState -> Engine r ExecutionState
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
                    stop state (cannotGetCurrentThreadErrorMessage "execAssertExceptional")
        else
            return state

execAssume :: ExecutionState -> Expression -> Engine r ExecutionState
execAssume state0 assumption0 = do
    (state1, concretizations) <- concretesOfType state0 ARRAYRuntimeType assumption0
    concretize concretizations state1 $ \ state2 -> do
        (state3, assumption1) <- evaluateAsBool state2 assumption0
        case assumption1 of
            Right True  ->  
                return state3
            Right False -> do
                debug "Constraint is infeasible"
                infeasible
            Left assumption2 -> do
                debug ("Adding constraint: '" ++ toString assumption2 ++ "'")
                return $ state3 & (constraints <>~ PathConstraints.singleton assumption2)

execInvocation :: ExecutionState -> Invocation -> Maybe Lhs -> Node -> Engine r (ExecutionState, Node)
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
                    stop state2 (expectedMethodMemberErrorMessage "execInvocation" name)
    | otherwise = 
        stop state0 (unresolvedErrorMessage "execInvocation")

execStaticMethod :: ExecutionState -> DeclarationMember -> [Expression] -> Maybe Lhs -> Node -> Engine r ExecutionState
execStaticMethod state method arguments lhs neighbour = do
    let parameters = method ^?! SL.params
    pushStackFrameOnCurrentThread state neighbour method lhs (zip parameters arguments)

execMethod :: ExecutionState -> DeclarationMember -> [Expression] -> Maybe Lhs -> Node -> (NonVoidType, Identifier) -> Engine r ExecutionState
execMethod state method arguments lhs neighbour this = do
    -- Construct the parameters and arguments, with 'this' as an implicit parameter.
    let parameters' = parameter' (fst this) this' : method ^?! SL.params
    let arguments'  = var' (snd this) (typeOf (fst this)) : arguments
    -- Push a new stack frame.
    pushStackFrameOnCurrentThread state neighbour method lhs (zip parameters' arguments')

execConstructor :: ExecutionState -> DeclarationMember -> [Expression] -> Maybe Lhs -> Node -> Engine r ExecutionState
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

execFork :: ExecutionState -> DeclarationMember -> [Expression] -> Engine r (ExecutionState, ThreadId)
execFork state member arguments
    | Just parent <- state ^. currentThreadId =
        spawn state parent member arguments
    | otherwise = 
        stop state (cannotGetCurrentThreadErrorMessage "execFork")

execMemberEntry :: ExecutionState -> Engine r ExecutionState
execMemberEntry state =
    -- Verify the pre condition if this is the first call.
    case state ^. programTrace of
        [] -> return state
        _  -> execAssertRequires state

execMemberExit :: ExecutionState -> RuntimeType -> Engine r (ExecutionState, Maybe ((), Node))
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
                    stop state1 (cannotGetCurrentThreadErrorMessage "execMemberExit")
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

execReturn :: ExecutionState -> Maybe Expression -> Engine r ExecutionState
execReturn state Nothing =
    return state

execReturn state0 (Just expression) = do
    (state1, concretizations) <- concretesOfType state0 ARRAYRuntimeType expression
    concretize concretizations state1 $ \ state2 -> do
        (state3, retval) <- evaluate state2 expression
        writeDeclaration state3 retval' retval

execException :: ExecutionState -> Engine r (ExecutionState, Maybe ((), Node))
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

execTryEntry :: ExecutionState -> Node -> Engine r ExecutionState
execTryEntry = insertHandler

execTryExit :: ExecutionState -> Engine r ExecutionState
execTryExit = removeLastHandler

execCatchEntry :: ExecutionState -> Engine r ExecutionState
execCatchEntry = removeLastHandler

execDeclare :: ExecutionState -> NonVoidType -> Identifier -> Engine r ExecutionState
execDeclare state0 ty var = do
    let value = defaultValue ty
    writeDeclaration state0 var value

execLock :: ExecutionState -> Identifier -> Engine r ExecutionState
execLock state0 var = do
    ref <- readDeclaration state0 var 
    case ref of
        Lit NullLit{} _ _ -> infeasible
        SymbolicRef{}     -> do
            (state1, concretizations) <- concretesOfType state0 ARRAYRuntimeType ref
            concretize concretizations state1 $ \ state2 ->
                execLock state2 var
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
                    stop state0 (cannotGetCurrentThreadErrorMessage "execLock")
        _ -> 
            stop state0 (expectedReferenceErrorMessage "execLock" ref)

execUnlock :: ExecutionState -> Identifier -> Engine r ExecutionState
execUnlock state var = do
    ref <- readDeclaration state var
    case ref of
        Ref{} -> 
            return $ state & (locks %~ LockSet.remove (ref ^?! SL.ref))
        _ -> 
            stop state (expectedConcreteReferenceErrorMessage "execUnock" ref)

execAssign :: ExecutionState -> Lhs -> Rhs -> Engine r ExecutionState
execAssign state0 _ RhsCall{} = 
    return state0
execAssign state0 lhs rhs = do
    (state1, value) <- execRhs state0 rhs
    execLhs state1 lhs value