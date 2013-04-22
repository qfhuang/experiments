{-# LANGUAGE NoMonomorphismRestriction #-}
module GraphTerm where

import qualified Data.Map as M
import qualified Data.Set as S
import Data.List
import Data.Maybe
import Control.Monad.State
import Data.Graph.Inductive.Query.Monad ((><))
{-import Control.Monad.Identity-}

-- TODO: will probably need this later for ad-hoc evaluation
{-bn_lift idx target =-}
  {-if idx >= target then idx + 1 else idx-}
{-bn_lower idx target =-}
  {-if idx == target then Nothing else-}
    {-Just (if idx > target then idx - 1 else idx)-}
{--- TODO: lift to make room for a new lambda binding; does this operation make sense on bn?-}
{--- bn_abstract ... =-}
{-bn_substitute idx target val =-}
  {-case bn_lower idx target of-}
    {-Nothing -> val-}
    {-Just bname -> Var bname-}
{--- TODO: term wrappers?-}
{-term_substitute rtsub term target val = tsub term-}
  {-where-}
    {-tsub (Var bname) = bn_substitute bname target val-}
    {-tsub (Lam body) = Lam $ rtsub body (target + 1) val-}
    {-tsub (App proc arg) = App (rtsub proc target val) (rtsub arg target val)-}

-- coinductive data dealt with by change in evaluation strategy to normal order
--   no need for explicit delay/force syntax (reserved for lower level languages?)
--   functions parameters are analyzed to see which can endanger termination
--   when termination is jeopardized by coinductively defined data, evaluation of
--   applications switches to normal order, thunking/delaying expressions
--     strictness analysis done to figure out when to force thunks before case scrutiny?

-- function cost analysis: per iteration/step, full undelayed process (may be infinite), parameterized by function parameters
-- possible nontermination as effect
-- termination analysis indicates dependency on the finiteness of certain parameters, maybe just in a sentence using AND and OR; failing this dependency indicates the function application needs to be delayed until forced (recursive calls will naturally do the same)
--   when operating dynamically, finding "delayed" expressions in these positions triggers further delay

type Address = Int
type Name = Int

type Nat = Integer
type SymUid = String
type SymName = String
type SymSet = (SymUid, [SymName])
type Symbol = (SymUid, SymName)

data ConstFiniteSet = CSNat [Nat] | CSInt [Integer] | CSSym SymSet
  deriving (Show, Eq)
data Constant = CNat Nat | CInt Integer | CSym Symbol
              | CInterpreted ConstFiniteSet Nat
  deriving (Show, Eq)
cfs_index (CSNat nats) (CNat nat) = _cfs_elemIndex nat nats
cfs_index (CSInt ints) (CInt int) = _cfs_elemIndex int ints
cfs_index (CSSym (uid0, names)) (CSym (uid1, name)) =
  if uid0 == uid1 then _cfs_elemIndex name names
    else Left "cfs_index: mismatching symbol family"
cfs_index _ _ = Left "cfs_index: mismatching constant and set type"
_cfs_elemIndex elem elems = Right . CNat $ toInteger idx
    where default_idx = length elems
          idx = fromMaybe default_idx $ elemIndex elem elems

-- TODO
-- memory store; addresses
-- TupleWrite and test
-- recursion-friendly pretty printing
-- switch to zipper contexts
--   small-step
--   generic context over subterms that are: Either still-a-term already-a-value
--     allows ad-hoc eval order (think user interaction)
--     any fixed eval order can also be defined
--       maintain and traverse a sequence of get/put functions over a context's remaining 'still-a-term' subterms
-- eval/substitute at arbitrary term positions
-- define evaluation orders as zipper traversals
-- try to simplify EvalCtrl
-- const/mutable regions?

-- NOTES
-- (ordered) (sub)sets of: nats; ints; symbols
--   unique ids for sets so tags can be distinguished/unforgeable
--   layering/association of ordered sets over nats to describe records on top of tuples
-- variable-sized tuple/array alloc, given initialization value
--   can be given abstract value (type) for size-only initialization
-- tuples:
--   allocation
--     indicate allocations performed in a mutable region: (mutable expr-that-allocates)
--       'mutable' means that mutability can be observed from a distance; implies sharing
--       linear/unshared tuples can be modified without having been allocated in a mutable region
--         allows efficient initialization dynamically-sized of yet-to-be-shared 'constant' tuples
--   read/write
--     in order to implement write, need to represent memory store and addresses into it
data ValueT term env value = Lam term env
                           | Tuple [value]
                           | Const Constant
                           | ConstFinSet ConstFiniteSet
                           | Tagged Constant value
                           | Undefined String
  deriving (Show, Eq)
data TermT term = Value (ValueT term () term)
                | Var Name
                | LetRec [term] term
                | App term term
                | TupleAlloc term
                | TupleRead term term
                | ConstFinSetIndex term term
                | TaggedGetConst term
                | TaggedGetPayload term
  deriving (Show, Eq)

data EvalCtrl a b c d e = EvalCtrl
  { ctrl_eval :: a
  , ctrl_wrap :: b
  , ctrl_unwrap :: c
  , ctrl_env_lookup :: d
  , ctrl_env_extend :: e }

evalT ctrl term env = case evT term of
  Left msg -> Undefined msg
  Right val -> val
  where
    eval = ctrl_eval ctrl
    wrap = ctrl_wrap ctrl
    unwrap = ctrl_unwrap ctrl
    evalUnwrap = unwrap . (`eval` env)
    env_lookup = ctrl_env_lookup ctrl
    env_extend = ctrl_env_extend ctrl

    apply proc arg = case unwrap proc of
      Lam body penv -> Right . unwrap $ eval body env'
        where env' = env_extend penv arg
      otherwise -> Left "expected Lam"

    untag ttagged = case unwrap $ eval ttagged env of
      Tagged const payload -> Right (const, payload)
      otherwise -> Left "expected Tagged"

    construct (Lam body ()) = Lam body env
    construct (Tuple vals) = Tuple $ map (`eval` env) vals
    construct (Const const) = Const const
    construct (ConstFinSet cfs) = ConstFinSet cfs
    construct (Tagged const val) = Tagged const $ eval val env
    construct (Undefined description) = Undefined description

    asTup (Tuple vals) = Right vals
    asTup _ = Left "expected Tuple"
    evalTup = asTup . evalUnwrap

    asConst (Const const) = Right const
    asConst _ = Left "expected Const"

    asNat val = do
      cnat <- asConst val
      case cnat of
        CNat nat -> Right $ fromInteger nat
        otherwise -> Left "expected Nat"
    evalNat = asNat . evalUnwrap

    asCfs (ConstFinSet cfs) = Right cfs
    asCfs _ = Left "expected ConstFinSet"

    evT (Value val) = Right $ construct val
    evT (Var name) = Right $ env_lookup env name
    evT (LetRec bindings body) = Right . unwrap $ eval body env'
      where env' = foldl env_extend env $ map (`eval` env') bindings
    evT (App tproc targ) = apply proc arg
      where proc = eval tproc env
            arg = eval targ env
    evT (TupleAlloc tsize) = do
      size <- evalNat tsize
      Right . Tuple $ replicate size undef
      where undef = wrap $ Undefined "TupleAlloc: uninitialized slot"
    evT (TupleRead ttup tidx) = do
      tup <- evalTup ttup
      idx <- evalNat tidx
      if idx < length tup then Right . unwrap $ tup !! idx
        else Left "TupleRead: index out of bounds"
    evT (ConstFinSetIndex tcfs tconst) = do
      cfs <- asCfs $ evalUnwrap tcfs
      const <- asConst $ evalUnwrap tconst
      index <- cfs_index cfs const
      Right $ Const index
    evT (TaggedGetConst ttagged) = do
      (tag, _) <- untag ttagged
      Right $ Const tag
    evT (TaggedGetPayload ttagged) = do
      (_, payload) <- untag ttagged
      Right $ unwrap payload

----------------------------------------------------------------
-- Simple guiding example
----------------------------------------------------------------
newtype SimpleTerm = SimpleTerm { simple_term :: TermT SimpleTerm }
  deriving (Show, Eq)
newtype SimpleValue =
  SimpleValue { simple_value :: ValueT SimpleTerm SimpleEnv SimpleValue }
  deriving (Show, Eq)
newtype SimpleEnv = SimpleEnv [SimpleValue]
  deriving (Show, Eq)
simple_env_lookup (SimpleEnv vals) name = simple_value $ vals !! name
simple_env_extend (SimpleEnv vals) val = SimpleEnv $ val : vals

simple_ctrl =
  EvalCtrl simple_eval SimpleValue simple_value simple_env_lookup simple_env_extend
simple_eval (SimpleTerm term) env = SimpleValue $ evalT simple_ctrl term env

app tp ta = SimpleTerm $ App tp ta
lam body = SimpleTerm . Value $ Lam body ()
var = SimpleTerm . Var
value = SimpleTerm . Value
tuple = value . Tuple
tupalloc sz = SimpleTerm $ TupleAlloc sz
tupread tup idx = SimpleTerm $ TupleRead tup idx
constant = value . Const
cnat = constant . CNat
cfsidx cfs const = SimpleTerm $ ConstFinSetIndex cfs const

-- TODO: recursion-friendly pretty-printing
test_recfunc0 = lam $ var 0
test_recfunc1 = lam $ app (var 3) $ cnat 64
test_recfunc2 = lam $ app (var 2) $ var 0
test_letrec = SimpleTerm $ LetRec [test_recfunc0, test_recfunc1, test_recfunc2] $ app (var 0) $ cnat 72

test_sym = constant . CSym $ ("global", "two")
test_cfs = value . ConstFinSet $ CSSym ("global", ["one", "two", "three"])
test_tup0 = tuple [cnat 0, cnat 1, cnat 2, cnat 3, cnat 4, cnat 5, cnat 6]
test_tup1 = tuple [cnat 7, cnat 8, cnat 9, cnat 10, cnat 11, cnat 12]
test_term = tuple [cnat 4,
                   app (lam $ var 0) (lam $ lam $ var 1),
                   tupread (tuple [cnat 11, cnat 421]) (cnat 1),
                   tupalloc (cnat 2),
                   cfsidx test_cfs test_sym,
                   test_letrec]
test = simple_eval test_term $ SimpleEnv []

----------------------------------------------------------------
-- Somewhat more heavy-duty approach
----------------------------------------------------------------
-- TODO: where to track open binders?
type Labeled term = ((), term)
type Addressed term = Either Address term
newtype ALTerm = ALTerm (Addressed (Labeled (TermT ALTerm)))
  deriving (Show, Eq)
