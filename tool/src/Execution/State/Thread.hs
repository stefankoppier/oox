module Execution.State.Thread(
      ThreadId(..)
    , StackFrame(StackFrame)
    , returnPoint, lhs, declarations, currentMember
    , Thread(Thread)
    , tid, parent, _pc, pc, callStack, handlerStack
) where

import qualified Data.Stack                 as T
import qualified Data.Map                   as M
import qualified Text.Pretty                as Pretty
import           Data.Graph.Inductive.Graph (Node)   
import           Control.Lens               (makeLenses, (^.))
import           Analysis.CFA.CFG
import           Language.Syntax

newtype ThreadId = ThreadId { unThreadId :: Int }

instance Show ThreadId where
    show (ThreadId tid) = show tid

instance Pretty.Pretty ThreadId where
    pretty = Pretty.int . unThreadId

instance Eq ThreadId where
    (ThreadId a) == (ThreadId b) = a == b
    
instance Ord ThreadId where
    (ThreadId a) <= (ThreadId b) = a <= b

data StackFrame = StackFrame
    { _returnPoint   :: Node
    , _lhs           :: Maybe Lhs
    , _declarations  :: M.Map Identifier Expression
    , _currentMember :: DeclarationMember }
    deriving (Show)

$(makeLenses ''StackFrame)

instance Pretty.Pretty StackFrame where
    pretty frame = 
        Pretty.text "returnPoint="  <> Pretty.pretty (frame ^. returnPoint)  Pretty.$+$
        Pretty.text "lhs="          <> Pretty.pretty (frame ^. lhs)          Pretty.$+$
        Pretty.text "declarations=" <> Pretty.pretty (frame ^. declarations)

data Thread = Thread 
    { _tid          :: ThreadId
    , _parent       :: ThreadId
    , _pc           :: CFGContext
    , _callStack    :: T.Stack StackFrame
    , _handlerStack :: T.Stack (Node, Int) }
    deriving (Show)

$(makeLenses ''Thread)

instance Eq Thread where
    t1 == t2 = t1 ^. tid == t2 ^. tid  

instance Ord Thread where
    t1 <= t2 = t1 ^. tid <= t2 ^. tid

instance Pretty.Pretty Thread where
    pretty thread = 
        Pretty.text "tid="       <> Pretty.pretty (thread ^. tid)       Pretty.$+$
        Pretty.text "parent="    <> Pretty.pretty (thread ^. parent)    Pretty.$+$
        Pretty.text "pc="        <> Pretty.pretty (thread ^. pc)        Pretty.$+$
        Pretty.text "parent="    <> Pretty.pretty (thread ^. parent)    Pretty.$+$
        Pretty.text "callstack=" <> Pretty.pretty (thread ^. callStack)