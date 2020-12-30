module Execution.Semantics.Exception where

import qualified Data.Stack as T
import           Analysis.CFA.CFG
import           Control.Lens ((&), (^.), (%~))
import           Execution.Effects
import           Execution.Errors
import           Execution.State
import           Execution.State.Thread (ThreadId, handlerStack)

insertHandler :: ExecutionState -> Node -> Engine r ExecutionState
insertHandler state handler 
    | Just thread <- getCurrentThread state = do
        debug ("Inserting an exception handler '" ++ show handler ++ "'")
        return $ updateThreadInState state (thread & (handlerStack %~ T.push (handler, 0)))
    | otherwise = 
        stop state (cannotGetCurrentThreadErrorMessage "insertHandler")
    
findLastHandler :: ExecutionState -> Maybe (Node, Int)
findLastHandler state = do
    thread <- getCurrentThread state
    T.peek (thread ^. handlerStack)

removeLastHandler :: ExecutionState -> Engine r ExecutionState
removeLastHandler state
    | Just thread <- getCurrentThread state = do
        return $ updateThreadInState state (thread & (handlerStack %~ T.pop))
    | otherwise = 
        stop state (cannotGetCurrentThreadErrorMessage "removeLastHandler")

incrementLastHandlerPopsOnCurrentThread :: ExecutionState -> Engine r ExecutionState
incrementLastHandlerPopsOnCurrentThread state
    | Just tid <- state ^. currentThreadId = 
        incrementLastHandlerPops state tid
    | otherwise = 
        stop state (cannotGetCurrentThreadErrorMessage "incrementLastHandlerPopsOnCurrentThread")

incrementLastHandlerPops :: ExecutionState -> ThreadId -> Engine r ExecutionState
incrementLastHandlerPops state tid
    | Just thread          <- getThread state tid
    , Just (handler, pops) <- T.peek (thread ^. handlerStack) = do
        debug ("Incrementing exception handler stack pop to '" ++ show (pops + 1) ++ "'")
        return $ updateThreadInState state (thread & (handlerStack %~ T.updateTop (handler, pops + 1)))
    | otherwise = 
        return state

decrementLastHandlerPops :: ExecutionState -> Engine r ExecutionState
decrementLastHandlerPops state
    | Nothing <- currentThread =
        stop state (cannotGetCurrentThreadErrorMessage "decrementLastHandlerPops")
    | Just thread          <- currentThread
    , Just (handler, pops) <- T.peek (thread ^. handlerStack) = do
        debug ("Decrementing exception handler stack pop to '" ++ show (pops - 1) ++ "'")
        return $ updateThreadInState state (thread & (handlerStack %~ T.updateTop (handler, pops - 1)))
    | otherwise =
        return state
    where currentThread = getCurrentThread state