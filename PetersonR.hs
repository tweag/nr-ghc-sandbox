{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module PetersonR
  ( structuredControl
  )
where

import Prelude hiding (succ)

import GHC.Cmm.Dataflow.Dominators

import Data.Maybe

import GHC.Cmm
import GHC.Cmm.Dataflow.Block
import GHC.Cmm.Dataflow.Collections
import GHC.Cmm.Dataflow.Graph
import GHC.Cmm.Dataflow.Label
import GHC.Utils.Panic
import GHC.Utils.Outputable (Outputable, text, (<+>), ppr)

import GHC.Wasm.ControlFlow

type MyBlock = CmmBlock



-- | Abstracts the kind of control flow we understand how to convert.
-- A block can be left unconditionally, conditionally on a predicate
-- of type `e`, or not at all.  "Switch" style control flow is not
-- yet implemented.

data ControlFlow e = Unconditional Label
                   | Conditional e Label Label
                   | TerminalFlow


-- | Peterson's stack.  If I can figure out how to make 
-- the code generator recursive, we can replace the stack
-- with a data structure whose only purpose is to track
-- the nexting level for exit statements.

type Stack = [StackFrame]
data StackFrame = PendingElse Label Label -- ^ YT
                | PendingEndif            -- ^ YF
                | PendingNode MyBlock     -- ^ ordinary node
                | EndLoop Label           -- ^ Peterson end node

instance Outputable StackFrame where
    ppr (PendingElse _ tl) = text "else" <+> ppr tl
    ppr (PendingEndif) = text "endif"
    ppr (PendingNode b) = text "node" <+> ppr (entryLabel b)
    ppr (EndLoop l) = text "loop" <+> ppr l

-- | Convert a Cmm CFG to structured control flow expressed as
-- a `WasmStmt`.

structuredControl :: forall node e s . (node ~ CmmNode)
                  => (CmmExpr -> e) -- ^ translator for expressions
                  -> (Block node O O -> s) -- ^ translator for straight-line code
                  -> GenCmmGraph node -- ^ CFG to be translated
                  -> WasmStmt s e
structuredControl txExpr txBlock g = doBlock (blockLabeled (g_entry g)) []
 where

   -- | `doBlock` basically handles Peterson's case 1: it emits code 
   -- from the block to the nearest merge node that the block dominates.
   -- `doBegins` takes the merge nodes that the block dominates, and it
   -- wraps the immediately preceding code in `begin...end`, so that
   -- control can transfer to the merge node by means of an exit statement.
   -- And `doBranch` implements a control transfer, which may be
   -- implemented by falling through or by a `br` instruction 
   -- created with `exit` or `continue`.

   doBlock  :: MyBlock -> Stack -> WasmStmt s e
   doBegins :: MyBlock -> [MyBlock] -> Stack -> WasmStmt s e
   doBranch :: Label -> Label -> Stack -> WasmStmt s e

   doBlock x stack = doBegins x (mergeDominees x) stack
     -- case 1 step 2 (done before step 1)
     -- note mergeDominees must be ordered with largest RP number first

   doBegins x (y:ys) stack =
       blockEndingIn y (doBegins x ys (PendingNode y:stack)) <> doBlock y stack
     where blockEndingIn y = wasmLabeled (entryLabel y) WasmBlock
   doBegins x [] stack =
       WasmLabel (Labeled xlabel undefined) <>
       if isHeader xlabel then
           wasmLabeled  xlabel WasmLoop (emitBlock x (EndLoop xlabel : stack))
       else
           emitBlock x stack

     -- rolls together case 1 step 6, case 2 step 1, case 2 step 3
     where emitBlock x stack =
             codeBody x <>
             case flowLeaving x of
               Unconditional l -> doBranch xlabel l stack -- case 1 step 6
               Conditional e t f -> -- case 1 step 5
                 wasmLabeled xlabel WasmIf
                      (txExpr e)
                      (doBranch xlabel t (PendingElse xlabel f : stack))
                      (doBranch xlabel f (PendingEndif : stack))
               TerminalFlow -> WasmReturn
                  -- case 1 step 6, case 2 steps 2 and 3
           xlabel = entryLabel x

   -- case 2
   doBranch from to stack 
      | isBackward from to = WasmContinue to i
           -- case 1 step 4
      | isMergeLabel to = WasmExit to i
      | otherwise = doBlock (blockLabeled to) stack
     where i = index to stack

   ---- everything else here is utility functions

   blockLabeled :: Label -> MyBlock
   rpnum :: Label -> RPNum -- ^ reverse postorder number of the labeled block
   forwardPreds :: Label -> [Label] -- ^ reachable predecessors of reachable blocks,
                                   -- via forward edges only
   isMergeLabel :: Label -> Bool
   isMergeBlock :: MyBlock -> Bool
   isHeader :: Label -> Bool -- ^ identify loop headers
   mergeDominees :: MyBlock -> [MyBlock]
     -- ^ merge nodes whose immediate dominator is the given block.
     -- They are produced with the largest RP number first,
     -- so the largest RP number is pushed on the stack first.
   dominates :: Label -> Label -> Bool
     -- ^ Domination relation (not just immediate domination)

   codeBody :: Block CmmNode C C -> WasmStmt s e
   codeBody (BlockCC _first middle _last) = WasmSlc (txBlock middle)



   blockLabeled l = fromJust $ mapLookup l blockmap
   GMany NothingO blockmap NothingO = g_graph g

   rpblocks :: [MyBlock]
   rpblocks = revPostorderFrom blockmap (g_entry g)

   foldEdges :: forall a . (Label -> Label -> a -> a) -> a -> a
   foldEdges f a =
     foldl (\a (from, to) -> f from to a)
           a
           [(entryLabel from, to) | from <- rpblocks, to <- successors from]

   forwardPreds = \l -> mapFindWithDefault [] l predmap
       where predmap :: LabelMap [Label]
             predmap = foldEdges addForwardEdge mapEmpty
             addForwardEdge from to pm
                 | isBackward from to = pm
                 | otherwise = addToList (from :) to pm

   isMergeLabel l = setMember l mergeNodes
   isMergeBlock = isMergeLabel . entryLabel                   

   mergeNodes :: LabelSet
   mergeNodes =
       setFromList [entryLabel n | n <- rpblocks, big (forwardPreds (entryLabel n))]
    where big [] = False
          big [_] = False
          big (_ : _ : _) = True

   isHeader = \l -> setMember l headers
      where headers :: LabelSet
            headers = foldMap headersPointedTo blockmap
            headersPointedTo block =
                setFromList [label | label <- successors block,
                                              dominates label (entryLabel block)]

   mergeDominees x = filter isMergeBlock $ idominees (entryLabel x)

   index _ [] = panic "destination label not on stack"
   index label (frame : stack)
       | matches label frame = 0
       | otherwise = 1 + index label stack
     where matches label (PendingNode b) = label == entryLabel b
           matches label (EndLoop l) = label == l
           matches _ _ = False

   idominees :: Label -> [MyBlock] -- sorted with highest rpnum first
   gwd = graphWithDominators g
   rpnum lbl = mapFindWithDefault (panic "label without reverse postorder number")
               lbl (gwd_rpnumbering gwd)
   (idominees, dominates) = (idominees, dominates)
       where addToDominees ds label rpnum =
               case idom label of
                 EntryNode -> ds
                 AllNodes -> panic "AllNodes appears as dominator"
                 NumberedNode { ds_label = dominator } ->
                     addToList (addDominee label rpnum) dominator ds

             dominees :: LabelMap Dominees
             dominees = mapFoldlWithKey addToDominees mapEmpty (gwd_rpnumbering gwd)

             idom :: Label -> DominatorSet -- immediate dominator
             idom lbl = mapFindWithDefault AllNodes lbl (gwd_dominators gwd)

             idominees lbl = map (blockLabeled . fst) $ mapFindWithDefault [] lbl dominees

             addDominee :: Label -> RPNum -> Dominees -> Dominees
             addDominee l rpnum [] = [(l, rpnum)]
             addDominee l rpnum ((l', rpnum') : pairs)
                 | rpnum > rpnum' = (l, rpnum) : (l', rpnum') : pairs
                 | otherwise = (l', rpnum') : addDominee l rpnum pairs

             dominates lbl blockname = lbl == blockname || dominatorsMember lbl (idom blockname)

   isBackward from to = rpnum to <= rpnum from -- self-edge counts as a backward edge
    -- XXX need to test a graph with a self-edge


flowLeaving :: MyBlock -> ControlFlow CmmExpr
flowLeaving b =
    case lastNode b of
      CmmBranch l -> Unconditional l
      CmmCondBranch c t f _ -> Conditional c t f
      CmmSwitch { } -> panic "switch not implemented"
      CmmCall { cml_cont = Just l } -> Unconditional l
      CmmCall { cml_cont = Nothing } -> TerminalFlow
      CmmForeignCall { succ = l } -> Unconditional l
      



type Dominees = [(Label, RPNum)] -- ugh. should be in `where` clause


addToList :: (IsMap map) => ([a] -> [a]) -> KeyOf map -> map [a] -> map [a]
addToList consx = mapAlter add
    where add Nothing = Just (consx [])
          add (Just xs) = Just (consx xs)


