module Execution.Semantics.PartialOrderReduction(
      isEnabled
    , por
) where

import Debug.Trace
import qualified GHC.Stack as GHC
import qualified Data.Set as S
import           Control.Lens ((&), (^?!), (^.), (.~), (?~))
import           Control.Monad
import           Data.Configuration
import           Data.Statistics
import           Execution.Effects
import           Execution.Errors
import           Execution.State
import           Execution.State.Thread
import           Execution.State.LockSet as LockSet
import           Execution.State.AliasMap as AliasMap (lookup)
import           Execution.State.InterleavingConstraints
import           Execution.Semantics.StackFrame
import           Analysis.CFA.CFG
import           Language.Syntax
import           Language.Syntax.Fold
import           Language.Syntax.DSL
import qualified Language.Syntax.Lenses as SL

isEnabled :: GHC.HasCallStack => ExecutionState -> Thread -> Engine r Bool
isEnabled state thread
    | (_, _, StatNode (Lock var _ _), _) <- thread ^. pc = do
        ref <- readDeclaration (state & currentThreadId ?~ (thread ^. tid)) var
        case ref of
            Lit NullLit{} _ _ ->
                infeasible
            SymbolicRef{} ->
                return True
            Ref ref _ _ ->
                case LockSet.lookup ref (state ^. locks) of
                    Just tid' -> return (tid' == thread ^. tid)
                    Nothing   -> return True
            _ ->
                stop state (expectedReferenceErrorMessage ref)
    | (_, _, StatNode (Join _ _), _) <- thread ^. pc =
        S.null <$> children state (thread ^. tid)
    | otherwise =
        return True

children :: ExecutionState -> ThreadId -> Engine r (S.Set Thread)
children state tid =
    return $ S.filter (\ thread -> thread ^. parent == tid) (state ^. threads)

por :: GHC.HasCallStack => ExecutionState -> [Thread] -> Engine r (ExecutionState, [Thread])
por state0 []      = deadlock state0
por state0 ts@[singleThread] = return (state0,ts)
por state0 threads = do
    config <- askConfig
    if not (applyPOR config)
        then
            return (state0, threads)
        else do
            let uniqueThreads = filter (isUniqueInterleaving state0) threads
            -- WP variant:
            --
            onlyDoLocals <-  filterM  (nextActionIsLocal state0) uniqueThreads
            let uniqueThreads2 = if null onlyDoLocals then uniqueThreads else take 1 onlyDoLocals
            -- measurePrunes (length threads - length uniqueThreads)
            measurePrunes (length threads - length uniqueThreads2)
            state1 <- generate state0 threads
            -- WP variant:
            -- return (state1, uniqueThreads)
            return (state1, uniqueThreads2)

-- Check if a thread would be "unique" on the current state.
-- A thread t is NOT unique if executing the next action of t
-- would lead to a state that would have been, or will be
-- explored through a different interleaved execution. if
-- t cannot be determined as non-unique, then we call it unique.
-- A thread that is unique will be explored (from the current
-- state). Else there is no need to explore the thread (since
-- its next action leads to a duplicate state anyway).
isUniqueInterleaving :: ExecutionState -> Thread -> Bool
isUniqueInterleaving state thread = do
    let trace       = state ^. programTrace
    let constraints = state ^. interleavingConstraints
    -- not . any (isUnique trace) $ constraints
    all (relativeUnique trace) $ constraints

    where
        --isUnique trace (IndependentConstraint previous current) =
        --    (thread ^. pc) == current && previous `elem` trace
        --isUnique _ NotIndependentConstraint{} =
        --    False
        relativeUnique trace (IndependentConstraint previous current) =
                not((thread ^. pc) == current && previous `elem` trace)
        relativeUnique _ NotIndependentConstraint{} =
                True

-- given the current state s, its set of interleaving-constraints consists
-- actuall of the constraints at the previous state s0 that leads to to
-- the current state s. The function below calculates the new set of
-- interleaving constraints on this s, and then updating this into s, to
-- prepare it for the transition to the next state.
generate :: GHC.HasCallStack => ExecutionState -> [Thread] -> Engine r ExecutionState
generate state threads = do
    -- generate the constraints for every pair of threads (x,y). Note that
    -- the pair is ordered x<y. :
    let pairs = [(x, y) | let list = threads, x <- list, y <- list, x < y]
    new <- foldM construct [] pairs
    return $ updateInterleavingConstraints state new
    where
        -- constructing the interleaving constraint for a given pair of
        -- threads (t1,t2) ... the ordering is t1<t2.
        construct :: InterleavingConstraints -> (Thread, Thread) -> Engine r InterleavingConstraints
        construct acc pair@(thread1, thread2) = do
            isIndep <- isIndependent state pair
            if isIndep
                then return (IndependentConstraint (thread1 ^. pc) (thread2 ^. pc) : acc)
                else return (NotIndependentConstraint (thread1 ^. pc) (thread2 ^. pc) : acc)


updateInterleavingConstraints :: ExecutionState -> InterleavingConstraints -> ExecutionState
updateInterleavingConstraints state new = do
    let original = state ^. interleavingConstraints
    -- let filtered = filter (isConflict new) original
    -- renaming ... notConflicting is a better name :|
    let filtered = filter (notConflicting new) original
    -- in the update, we include all new constrainst + some of the old
    -- constraints, if they do not conflict with the new ones:
    state & (interleavingConstraints .~ (filtered ++ new))

{-
isConflict :: [InterleavingConstraint] -> InterleavingConstraint -> Bool
isConflict _   IndependentConstraint{}          = False
isConflict new (NotIndependentConstraint x1 y1) = flip any new $ \case
    (IndependentConstraint x2 y2) -> S.fromList [x1, y1] `S.disjoint` S.fromList [x2, y2]
    NotIndependentConstraint{}    -> False
-}

-- renaming:
-- Check if a given old constraint c would be non-conflicting with a set of
-- new constraints.
-- This seems to allow only non-independence constraints...
--
notConflicting :: [InterleavingConstraint] -> InterleavingConstraint -> Bool
-- if c specifies dependency is considered as conflicing... so we drop it:
notConflicting  _   IndependentConstraint{}          = False
-- if c specifies non-dependency between threads x1 and y1; we keep it (it is
-- non-conflicting) if either x1 or y1 appears in an Independence constraint in
-- the new. ??? that does not make sense....
notConflicting  new (NotIndependentConstraint x1 y1) = flip any new $ \case
    (IndependentConstraint x2 y2) -> S.fromList [x1, y1] `S.disjoint` S.fromList [x2, y2]
    NotIndependentConstraint{}    -> False


type ReadWriteSet = (S.Set Reference, S.Set Reference)

--
-- WP variant
-- check if a thread's first action only access local-vars:
nextActionIsLocal :: GHC.HasCallStack => ExecutionState -> Thread -> Engine r Bool
nextActionIsLocal state thread = do
    (writes,rds) <- dependentOperationsOfT state thread
    return (null writes && null rds)


isIndependent :: GHC.HasCallStack => ExecutionState -> (Thread, Thread) -> Engine r Bool
isIndependent state (thread1, thread2) = do
    (wT1, rT1) <- dependentOperationsOfT state thread1
    (wT2, rT2) <- dependentOperationsOfT state thread2
    -- WP variant, if thread1 only access local-vars and tr2 not, we will
    -- declare t1,t2 (in that direction!) to be dependent:
    -- return $ S.disjoint wT1 wT2 && S.disjoint rT1 wT2 && S.disjoint rT2 wT1
    if null wT1 && null rT1
       then return False
       else if (S.member minBound wT1 && (not(null wT2) || not(null rT2)))
                || (S.member minBound rT1 && not(null wT2))
                || (S.member minBound wT2 && (not(null wT1) || not(null rT1)))
                || (S.member minBound rT2 && not(null wT1))
             then return False
             else return $ S.disjoint wT1 wT2 && S.disjoint rT1 wT2 && S.disjoint rT2 wT1

-- | Returns the reads and writes of the current thread.
dependentOperationsOfT :: GHC.HasCallStack => ExecutionState -> Thread -> Engine r ReadWriteSet
dependentOperationsOfT state thread = dependentOperationsOfN state (thread ^. tid) (thread ^. pc)

-- | Returns the reads and writes of the current program counter.
dependentOperationsOfN :: GHC.HasCallStack => ExecutionState -> ThreadId -> CFGContext -> Engine r ReadWriteSet
dependentOperationsOfN state tid (_, _, StatNode stat, _)
    = dependentOperationsOfS state tid stat
dependentOperationsOfN _ _ _
    = return (S.empty, S.empty)

-- | Returns the reads and writes of the current statement.
dependentOperationsOfS :: GHC.HasCallStack => ExecutionState -> ThreadId -> Statement -> Engine r ReadWriteSet
dependentOperationsOfS state tid (Assign lhs rhs _ _) = (,)        <$> dependentOperationsOfLhs state tid lhs <*> dependentOperationsOfRhs state tid rhs
dependentOperationsOfS state tid (Assert ass _ _)     = (,S.empty) <$> dependentOperationsOfE state tid ass
dependentOperationsOfS state tid (Assume ass _ _)     = (,S.empty) <$> dependentOperationsOfE state tid ass
dependentOperationsOfS state tid (Lock var _ _)       = (\ refs -> (refs, refs)) <$> getReferences state tid var
dependentOperationsOfS state tid (Unlock var _ _)     = (\ refs -> (refs, refs)) <$> getReferences state tid var
dependentOperationsOfS _     _   _                    = return (S.empty, S.empty)

dependentOperationsOfLhs :: ExecutionState -> ThreadId -> Lhs -> Engine r (S.Set Reference)
dependentOperationsOfLhs _     _   LhsVar{}               = return S.empty
dependentOperationsOfLhs state tid (LhsField var _ _ _ _) = getReferences state tid var
dependentOperationsOfLhs state tid (LhsElem var _ _ _)    = getReferences state tid var

dependentOperationsOfRhs :: ExecutionState -> ThreadId -> Rhs -> Engine r (S.Set Reference)
dependentOperationsOfRhs _     _   RhsExpression{}      = return S.empty
dependentOperationsOfRhs state tid (RhsField var _ _ _) = getReferences state tid (var ^?! SL.var)
dependentOperationsOfRhs state tid (RhsElem var _ _ _)  = getReferences state tid (var ^?! SL.var)
dependentOperationsOfRhs _     _   RhsCall{}            = return S.empty
dependentOperationsOfRhs _     _   RhsArray{}           = return S.empty

dependentOperationsOfE :: GHC.HasCallStack => ExecutionState -> ThreadId -> Expression -> Engine r (S.Set Reference)
dependentOperationsOfE state tid = foldExpression algebra
    where
        algebra = monoidMExpressionAlgebra
            { fForall = \ _ _ domain _ _ _ -> getReferences state tid domain
            , fExists = \ _ _ domain _ _ _ -> getReferences state tid domain }

getReferences :: GHC.HasCallStack => ExecutionState -> ThreadId -> Identifier -> Engine r (S.Set Reference)
getReferences state tid var = do
    ref <- readDeclaration (state & currentThreadId ?~ tid) var
    case ref of
        Lit NullLit{} _ _ ->
            return S.empty
        Ref{} ->
            return $ S.singleton (ref ^?! SL.ref)
        SymbolicRef{}     ->
            case AliasMap.lookup (ref ^?! SL.var) (state ^. aliasMap) of
                Just aliases -> return . S.map (^?! SL.ref) . S.filter (/= lit' nullLit') $ aliases
                Nothing      -> return $ S.singleton minBound
                                -- stop state (trace (">>> " ++ show var) noAliasesErrorMessage)
        _ ->
            stop state (expectedReferenceErrorMessage ref)
