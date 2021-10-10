module Execution.Engine(
    execute
) where

import qualified GHC.Stack as GHC
import qualified Data.Set as S
import           Data.Maybe (fromJust)
import           System.Random.Shuffle
import           Control.Monad hiding (guard)
import           Control.Applicative
import           Control.Lens ((&), (^?!), (^.), (%~), (-~), (.~), (?~), Field2(_2))
import           Data.Configuration
import           Data.Error
import           Data.Statistics
import           Logger
import           Language.Syntax
import qualified Language.Syntax.Lenses as SL
import           Analysis.CFA.CFG
import           Analysis.SymbolTable
import           Execution.Effects
import           Execution.Errors
import           Execution.Semantics
import           Execution.Semantics.Concretization
import           Execution.Semantics.PartialOrderReduction
import           Execution.State
import           Execution.State.Thread
import           Execution.Result

--------------------------------------------------------------------------------
-- Symbolic Execution
--------------------------------------------------------------------------------

execute :: Members [Reader Configuration, Error ErrorMessage, State Statistics, Trace, Embed IO] r
    => SymbolTable -> ControlFlowGraph -> Sem r VerificationResult
execute table cfg = do
    config@Configuration{entryPoint} <- ask
    symbols <- maybe (throw (unknownEntryPointError entryPoint)) return (lookupConfigurationString entryPoint table)
    case S.toList symbols of
        [symbol] -> do
            let initialMethod = getMember symbol
            result <- test config cfg table initialMethod
            case result of
                Left res -> return res
                Right _  -> return Valid
        _        -> throw (unknownEntryPointError entryPoint)

test :: Members [State Statistics, Trace, Embed IO] r =>
    Configuration -> ControlFlowGraph -> SymbolTable -> DeclarationMember -> Sem r (Either VerificationResult [ExecutionState])
test config cfg table method = runError (runNonDet (evalCache (runReader (config, cfg, table) (start emptyState method))))

start :: ExecutionState -> DeclarationMember -> Engine r ExecutionState
start state0 initialMethod = do
    config <- askConfig
    let state1 = state0 & remainingK .~ maximumDepth config & currentThreadId ?~ processTid
    (state2, tid) <- execFork state1 initialMethod arguments
    let state3 = state2 & (currentThreadId ?~ tid)
    -- Add the pre-condition as assumption, branch if it contains an array.
    case initialMethod ^?! SL.specification ^. SL.requires of
        Nothing         -> execP state3
        Just assumption -> do
            state4 <- execAssume state3 assumption
            execP state4
    where
        -- TODO: add support for non-static and constructors
        arguments            = map createArgument (initialMethod ^?! SL.params)
        createArgument param = createSymbolicVar (param ^?! SL.name) (param ^?! SL.ty)

{- WP does not work...
foo :: ExecutionState -> [Expression] -> Engine r ExecutionState
foo state [] = return state
foo state (v:others) = do
    state2 <- initializeSymbolicRef state v
    state3 <- foo state2 others
    return state3
-}

--------------------------------------------------------------------------------
-- Process Execution

-- | Symbolically executes the program.
execP :: GHC.HasCallStack => ExecutionState -> Engine r ExecutionState
execP state0 = do
    let allThreads = state0 ^. threads
    if null allThreads
        then finish state0
        else do
            measureBranches allThreads
            enabledThreads    <- filterM (isEnabled state0) (S.toList allThreads)
            (state1, threads) <- por state0 enabledThreads
            config            <- askConfig
            if applyRandomInterleaving config
                then do
                    shuffledThreads <- embed (shuffleM threads)
                    branch' (\ thread -> execT (state1 & (currentThreadId ?~ (thread ^. tid))) (thread ^. pc)) shuffledThreads
                else
                    branch' (\ thread -> execT (state1 & (currentThreadId ?~ (thread ^. tid))) (thread ^. pc)) threads

--------------------------------------------------------------------------------
-- Thread Execution

-- | Symbolically executes the thread.
execT :: GHC.HasCallStack => ExecutionState -> CFGContext -> Engine r ExecutionState
execT state (_, _, ExceptionalNode, _) = do
    state1 <- execException state
    uncurry stepM state1

execT state0 (_, _, StatNode (Call invocation _ _), [(_, neighbour)]) = do
    (state1, entry) <- execInvocation state0 invocation Nothing neighbour
    step state1 ((), entry)

execT state0 (_, _, StatNode Call{}, neighbours) =
    stop state0 (expectedNumberOfNeighboursErrorMessage 1 (length neighbours))

-- A Member Entry
execT state0 (_, _, MemberEntry{}, neighbours) = do
    state1 <- execMemberEntry state0
    branch (step state1) neighbours

-- A Member Exit
execT state0 (_, _, MemberExit returnTy _ _ _, []) = do
    state1 <- execMemberExit state0 returnTy
    uncurry stepM state1

execT state0 (_, _, MemberExit{}, neighbours) =
    stop state0 (expectedNumberOfNeighboursErrorMessage 0 (length neighbours))

-- A Try Entry
execT state0 (_, _, TryEntry handler, neighbours) = do
    state1 <- execTryEntry state0 handler
    branch (step state1) neighbours

-- A Try Exit
execT state0 (_, _, TryExit, neighbours) = do
    state1 <- execTryExit state0
    branch (step state1) neighbours

-- A Catch Entry
execT state0 (_, _, CatchEntry, neighbours) = do
    state1 <- execCatchEntry state0
    branch (step state1) neighbours

-- A Catch Exit
execT state (_, _, CatchExit, neighbours) =
    branch (step state) neighbours

--------------------------------------------------------------------------------
-- Statement Execution

-- A Declare Statement
execT state0 (_, _, StatNode (Declare ty var _ _), neighbours) = do
    state1 <- execDeclare state0 ty var
    branch (step state1) neighbours

-- | An Assign Statement with a Call rhs
execT state0 (_, _, StatNode (Assign lhs (RhsCall invocation _ _) _ _), [(_, neighbour)]) = do
    (state1, entry) <- execInvocation state0 invocation (Just lhs) neighbour
    step state1 ((), entry)

-- | An Assign Statement
execT state0 (_, _, StatNode (Assign lhs rhs _ _), neighbours) = do
    state1 <- execAssign state0 lhs rhs
    branch (step state1) neighbours

-- An Assert Statement
execT state0 (_, _, StatNode (Assert assertion _ _), neighbours) = do
    state1 <- execAssert state0 assertion
    branch (step state1) neighbours

-- An Assume Statement
execT state0 (_, _, StatNode (Assume assumption _ _), neighbours) = do
    state1 <- execAssume state0 assumption
    branch (step state1) neighbours

-- A Return Statement
execT state0 (_, _, StatNode (Return expression _ _), neighbours) = do
    state1 <- execReturn state0 expression
    branch (step state1) neighbours

-- A Lock Statement
execT state0 (_, _, StatNode (Lock var _ _), neighbours) = do
    state1 <- execLock state0 var
    branch (step state1) neighbours

-- An Unlock Statement
execT state0 (_, _, StatNode (Unlock var _ _), neighbours) = do
    state1 <- execUnlock state0 var
    branch (step state1) neighbours

-- A Fork Statement
execT state0 (_, _, StatNode (Fork invocation _ _), neighbours) = do
    let method    = fromJust (invocation ^. SL.resolved) ^. _2
    -- TODO: the next line does not work for constructors.
    let arguments = invocation ^. SL.arguments
    (state1, _) <- execFork state0 method arguments
    branch (step state1) neighbours

-- Any other Statement
execT state (_, _, StatNode _, neighbours) =
    branch (step state) neighbours

step :: ExecutionState -> ((), Node) -> Engine r ExecutionState
step state = stepM state . Just

stepM :: ExecutionState -> Maybe ((), Node) -> Engine r ExecutionState
stepM state0 neighbour
    | state0 ^. remainingK > 1 = do
        measureMaximumForks (state0 ^. numberOfForks)
        state1 <- updatePC state0 neighbour
        execP $ state1 & (remainingK -~ 1) & (currentThreadId .~ Nothing)
    | otherwise =
        finish state0

updatePC :: ExecutionState -> Maybe ((), Node) -> Engine r ExecutionState
updatePC state Nothing =
    return state
updatePC state (Just (_, node)) = do
    cfg <- askCFG
    case getCurrentThread state of
        Nothing      ->
            return state
        Just thread0 -> do
            debug ("Updating pc to '" ++ show node ++ "'")
            let thread1 = thread0 & (pc .~ context cfg node)
            return $ updateThreadInState state thread1 & (programTrace %~ ((_tid thread0, thread0 ^. pc) :))

--------------------------------------------------------------------------------
-- Brancing functions
--------------------------------------------------------------------------------

branch :: (Foldable f, Alternative f) => (a -> Engine r b) -> f a -> Engine r b
branch f options = do
    measureBranches options
    foldr (\ x a -> f x <|> a) empty options

branch' :: (Foldable f, Alternative f) => (a -> Engine r b) -> f a -> Engine r b
branch' f = foldr (\ x a -> f x <|> a) empty
