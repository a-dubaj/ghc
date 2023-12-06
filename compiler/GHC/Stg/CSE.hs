{-# LANGUAGE TypeFamilies #-}

{-|
Note [CSE for Stg]
~~~~~~~~~~~~~~~~~~

This module implements a simple common subexpression elimination pass for STG.
This is useful because there are expressions that we want to common up (because
they are operationally equivalent), but that we cannot common up in Core, because
their types differ.
This was originally reported as #9291.

There are two types of common code occurrences that we aim for, see
Note [Case 1: CSEing allocated closures] and
Note [Case 2: CSEing case binders] below.


Note [Case 1: CSEing allocated closures]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The first kind of CSE opportunity we aim for is generated by this Haskell code:

    bar :: a -> (Either Int a, Either Bool a)
    bar x = (Right x, Right x)

which produces this Core:

    bar :: forall a. a -> (Either Int a, Either Bool a)
    bar @a x = (Right @Int @a x, Right @Bool @a x)

where the two components of the tuple are different terms, and cannot be
commoned up (easily). On the STG level we have

    bar [x] = let c1 = Right [x]
                  c2 = Right [x]
              in (c1,c2)

and now it is obvious that we can write

    bar [x] = let c1 = Right [x]
              in (c1,c1)

instead.


Note [Case 2: CSEing case binders]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The second kind of CSE opportunity we aim for is more interesting, and
came up in #9291 and #5344: The Haskell code

    foo :: Either Int a -> Either Bool a
    foo (Right x) = Right x
    foo _         = Left False

produces this Core

    foo :: forall a. Either Int a -> Either Bool a
    foo @a e = case e of b { Left n -> …
                           , Right x -> Right @Bool @a x }

where we cannot CSE `Right @Bool @a x` with the case binder `b` as they have
different types. But in STG we have

    foo [e] = case e of b { Left [n] -> …
                          , Right [x] -> Right [x] }

and nothing stops us from transforming that to

    foo [e] = case e of b { Left [n] -> …
                          , Right [x] -> b}


Note that this can revive dead case binders (e.g. "b" above), hence we zap
occurrence information on all case binders during STG CSE.
See Note [Dead-binder optimisation] in GHC.StgToCmm.Expr.


Note [StgCse after unarisation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Consider two unboxed sum terms:

    (# 1 | #) :: (# Int | Int# #)
    (# 1 | #) :: (# Int | Int  #)

These two terms are not equal as they unarise to different unboxed
tuples. However if we run StgCse before Unarise, it'll think the two
terms (# 1 | #) are equal, and replace one of these with a binder to
the other. That's bad -- #15300.

Solution: do unarise first.

-}

module GHC.Stg.CSE (stgCse) where

import GHC.Prelude

import GHC.Core.DataCon
import GHC.Types.Id
import GHC.Stg.Syntax
import GHC.Types.Basic (isWeakLoopBreaker)
import GHC.Types.Var.Env
import GHC.Core (AltCon(..))
import Data.List (mapAccumL)
import Data.Maybe (fromMaybe)
import GHC.Core.Map.Expr
import GHC.Data.TrieMap
import GHC.Types.Name.Env
import Control.Monad( (>=>) )

--------------
-- The Trie --
--------------

-- A lookup trie for data constructor applications, i.e.
-- keys of type `(DataCon, [StgArg])`, following the patterns in GHC.Data.TrieMap.

data StgArgMap a = SAM
    { sam_var :: DVarEnv a
    , sam_lit :: LiteralMap a
    }

-- TODO(22292): derive
instance Functor StgArgMap where
    fmap f SAM { sam_var = varm, sam_lit = litm } = SAM
      { sam_var = fmap f varm, sam_lit = fmap f litm }

instance TrieMap StgArgMap where
    type Key StgArgMap = StgArg
    emptyTM  = SAM { sam_var = emptyTM
                   , sam_lit = emptyTM }
    lookupTM (StgVarArg var) = sam_var >.> lkDFreeVar var
    lookupTM (StgLitArg lit) = sam_lit >.> lookupTM lit
    alterTM  (StgVarArg var) f m = m { sam_var = sam_var m |> xtDFreeVar var f }
    alterTM  (StgLitArg lit) f m = m { sam_lit = sam_lit m |> alterTM lit f }
    foldTM k m = foldTM k (sam_var m) . foldTM k (sam_lit m)
    filterTM f (SAM {sam_var = varm, sam_lit = litm}) =
        SAM { sam_var = filterTM f varm, sam_lit = filterTM f litm }

newtype ConAppMap a = CAM { un_cam :: DNameEnv (ListMap StgArgMap a) }

-- TODO(22292): derive
instance Functor ConAppMap where
    fmap f = CAM . fmap (fmap f) . un_cam
    {-# INLINE fmap #-}

instance TrieMap ConAppMap where
    type Key ConAppMap = (DataCon, [StgArg])
    emptyTM  = CAM emptyTM
    lookupTM (dataCon, args) = un_cam >.> lkDNamed dataCon >=> lookupTM args
    alterTM  (dataCon, args) f m =
        m { un_cam = un_cam m |> xtDNamed dataCon |>> alterTM args f }
    foldTM k = un_cam >.> foldTM (foldTM k)
    filterTM f = un_cam >.> fmap (filterTM f) >.> CAM

-----------------
-- The CSE Env --
-----------------

-- | The CSE environment. See Note [CseEnv Example]
data CseEnv = CseEnv
    { ce_conAppMap :: ConAppMap OutId
        -- ^ The main component of the environment is the trie that maps
        --   data constructor applications (with their `OutId` arguments)
        --   to an in-scope name that can be used instead.
        --   This name is always either a let-bound variable or a case binder.
    , ce_subst     :: IdEnv OutId
        -- ^ This substitution is applied to the code as we traverse it.
        --   Entries have one of two reasons:
        --
        --   * The input might have shadowing (see Note [Shadowing in Core]),
        --     so we have to rename some binders as we traverse the tree.
        --   * If we remove `let x = Con z` because  `let y = Con z` is in scope,
        --     we note this here as x ↦ y.
    , ce_bndrMap     :: IdEnv OutId
        -- ^ If we come across a case expression case x as b of … with a trivial
        --   binder, we add b ↦ x to this.
        --   This map is *only* used when looking something up in the ce_conAppMap.
        --   See Note [Trivial case scrutinee]
    , ce_in_scope  :: InScopeSet
        -- ^ The third component is an in-scope set, to rename away any
        --   shadowing binders
    }

{-|
Note [CseEnv Example]
~~~~~~~~~~~~~~~~~~~~~
The following tables shows how the CseEnvironment changes as code is traversed,
as well as the changes to that code.

  InExpr                         OutExpr
     conAppMap                   subst          in_scope
  ───────────────────────────────────────────────────────────
  -- empty                       {}             {}
  case … as a of {Con x y ->     case … as a of {Con x y ->
  -- Con x y ↦ a                 {}             {a,x,y}
  let b = Con x y                (removed)
  -- Con x y ↦ a                 b↦a            {a,x,y,b}
  let c = Bar a                  let c = Bar a
  -- Con x y ↦ a, Bar a ↦ c      b↦a            {a,x,y,b,c}
  let c = some expression        let c' = some expression
  -- Con x y ↦ a, Bar a ↦ c      b↦a, c↦c',     {a,x,y,b,c,c'}
  let d = Bar b                  (removed)
  -- Con x y ↦ a, Bar a ↦ c      b↦a, c↦c', d↦c {a,x,y,b,c,c',d}
  (a, b, c d)                    (a, a, c' c)
-}

initEnv :: InScopeSet -> CseEnv
initEnv in_scope = CseEnv
    { ce_conAppMap = emptyTM
    , ce_subst     = emptyVarEnv
    , ce_bndrMap   = emptyVarEnv
    , ce_in_scope  = in_scope
    }

-------------------
normaliseConArgs :: CseEnv -> [OutStgArg] -> [OutStgArg]
-- See Note [Trivial case scrutinee]
normaliseConArgs env args
  = map go args
  where
    bndr_map = ce_bndrMap env
    go (StgVarArg v  ) = StgVarArg (normaliseId bndr_map v)
    go (StgLitArg lit) = StgLitArg lit

normaliseId :: IdEnv OutId -> OutId -> OutId
normaliseId bndr_map v = case lookupVarEnv bndr_map v of
                           Just v' -> v'
                           Nothing -> v

addTrivCaseBndr :: OutId -> OutId -> CseEnv -> CseEnv
-- See Note [Trivial case scrutinee]
addTrivCaseBndr from to env
    = env { ce_bndrMap = extendVarEnv bndr_map from norm_to }
    where
      bndr_map = ce_bndrMap env
      norm_to = normaliseId bndr_map to

envLookup :: DataCon -> [OutStgArg] -> CseEnv -> Maybe OutId
envLookup dataCon args env
  = lookupTM (dataCon, normaliseConArgs env args)
             (ce_conAppMap env)
    -- normaliseConArgs: See Note [Trivial case scrutinee]

addDataCon :: OutId -> DataCon -> [OutStgArg] -> CseEnv -> CseEnv
-- Do not bother with nullary data constructors; they are static anyway
addDataCon _ _ [] env = env
addDataCon bndr dataCon args env
  = env { ce_conAppMap = new_env }
  where
    new_env = insertTM (dataCon, normaliseConArgs env args)
                       bndr (ce_conAppMap env)
    -- normaliseConArgs: See Note [Trivial case scrutinee]

-------------------
forgetCse :: CseEnv -> CseEnv
forgetCse env = env { ce_conAppMap = emptyTM }
    -- See Note [Free variables of an StgClosure]

addSubst :: OutId -> OutId -> CseEnv -> CseEnv
addSubst from to env
    = env { ce_subst = extendVarEnv (ce_subst env) from to }

substArgs :: CseEnv -> [InStgArg] -> [OutStgArg]
substArgs env = map (substArg env)

substArg :: CseEnv -> InStgArg -> OutStgArg
substArg env (StgVarArg from) = StgVarArg (substVar env from)
substArg _   (StgLitArg lit)  = StgLitArg lit

substVar :: CseEnv -> InId -> OutId
substVar env id = fromMaybe id $ lookupVarEnv (ce_subst env) id

-- Functions to enter binders

-- This is much simpler than the equivalent code in GHC.Core.Subst:
--  * We do not substitute type variables, and
--  * There is nothing relevant in GHC.Types.Id.Info at this stage
--    that needs substitutions.
-- Therefore, no special treatment for a recursive group is required.

substBndr :: CseEnv -> InId -> (CseEnv, OutId)
substBndr env old_id
  = (new_env, new_id)
  where
    new_id = uniqAway (ce_in_scope env) old_id
    no_change = new_id == old_id
    env' = env { ce_in_scope = ce_in_scope env `extendInScopeSet` new_id }
    new_env | no_change = env'
            | otherwise = env' { ce_subst = extendVarEnv (ce_subst env) old_id new_id }

substBndrs :: CseEnv -> [InVar] -> (CseEnv, [OutVar])
substBndrs env bndrs = mapAccumL substBndr env bndrs

substPairs :: CseEnv -> [(InVar, a)] -> (CseEnv, [(OutVar, a)])
substPairs env bndrs = mapAccumL go env bndrs
  where go env (id, x) = let (env', id') = substBndr env id
                         in (env', (id', x))

-- Main entry point

stgCse :: [InStgTopBinding] -> [OutStgTopBinding]
stgCse binds = snd $ mapAccumL stgCseTopLvl emptyInScopeSet binds

-- Top level bindings.
--
-- We do not CSE these, as top-level closures are allocated statically anyways.
-- Also, they might be exported.
-- But we still have to collect the set of in-scope variables, otherwise
-- uniqAway might shadow a top-level closure.

stgCseTopLvl :: InScopeSet -> InStgTopBinding -> (InScopeSet, OutStgTopBinding)
stgCseTopLvl in_scope t@(StgTopStringLit _ _) = (in_scope, t)
stgCseTopLvl in_scope (StgTopLifted (StgNonRec bndr rhs))
    = (in_scope'
      , StgTopLifted (StgNonRec bndr (stgCseTopLvlRhs in_scope rhs)))
  where in_scope' = in_scope `extendInScopeSet` bndr

stgCseTopLvl in_scope (StgTopLifted (StgRec eqs))
    = ( in_scope'
      , StgTopLifted (StgRec [ (bndr, stgCseTopLvlRhs in_scope' rhs) | (bndr, rhs) <- eqs ]))
  where in_scope' = in_scope `extendInScopeSetList` [ bndr | (bndr, _) <- eqs ]

stgCseTopLvlRhs :: InScopeSet -> InStgRhs -> OutStgRhs
stgCseTopLvlRhs in_scope (StgRhsClosure ext ccs upd args body typ)
    = let body' = stgCseExpr (initEnv in_scope) body
      in  StgRhsClosure ext ccs upd args body' typ
stgCseTopLvlRhs _ (StgRhsCon ccs dataCon mu ticks args typ)
    = StgRhsCon ccs dataCon mu ticks args typ

------------------------------
-- The actual AST traversal --
------------------------------

-- Trivial cases
stgCseExpr :: CseEnv -> InStgExpr -> OutStgExpr
stgCseExpr env (StgApp fun args)
    = StgApp fun' args'
  where fun' = substVar env fun
        args' = substArgs env args
stgCseExpr _ (StgLit lit)
    = StgLit lit
stgCseExpr env (StgOpApp op args tys)
    = StgOpApp op args' tys
  where args' = substArgs env args
stgCseExpr env (StgTick tick body)
    = let body' = stgCseExpr env body
      in StgTick tick body'
stgCseExpr env (StgCase scrut bndr ty alts)
    = mkStgCase scrut' bndr'' ty alts'
  where
    scrut' = stgCseExpr env scrut
    (env1, bndr') = substBndr env bndr
    -- we must zap occurrence information on the case binder
    -- because CSE might revive it.
    -- See Note [Dead-binder optimisation] in GHC.StgToCmm.Expr
    bndr'' = zapIdOccInfo bndr'
    env2 | StgApp trivial_scrut [] <- scrut'
         = addTrivCaseBndr bndr trivial_scrut env1
                 -- See Note [Trivial case scrutinee]
         | otherwise
         = env1
    alts' = map (stgCseAlt env2 ty bndr'') alts


-- A constructor application.
-- To be removed by a variable use when found in the CSE environment
stgCseExpr env (StgConApp dataCon n args tys)
    | Just bndr' <- envLookup dataCon args' env
    = StgApp bndr' []
    | otherwise
    = StgConApp dataCon n args' tys
  where args' = substArgs env args

-- Let bindings
-- The binding might be removed due to CSE (we do not want trivial bindings on
-- the STG level), so use the smart constructor `mkStgLet` to remove the binding
-- if empty.
stgCseExpr env (StgLet ext binds body)
    = let (binds', env') = stgCseBind env binds
          body' = stgCseExpr env' body
      in mkStgLet (StgLet ext) binds' body'
stgCseExpr env (StgLetNoEscape ext binds body)
    = let (binds', env') = stgCseBind env binds
          body' = stgCseExpr env' body
      in mkStgLet (StgLetNoEscape ext) binds' body'

-- Case alternatives
-- Extend the CSE environment
stgCseAlt :: CseEnv -> AltType -> OutId -> InStgAlt -> OutStgAlt
stgCseAlt env ty case_bndr GenStgAlt{alt_con=DataAlt dataCon, alt_bndrs=args, alt_rhs=rhs}
    = let (env1, args') = substBndrs env args
          env2
            -- To avoid dealing with unboxed sums StgCse runs after unarise and
            -- should maintain invariants listed in Note [Post-unarisation
            -- invariants]. One of the invariants is that some binders are not
            -- used (unboxed tuple case binders) which is what we check with
            -- `stgCaseBndrInScope` here. If the case binder is not in scope we
            -- don't add it to the CSE env. See also #15300.
            | stgCaseBndrInScope ty True -- CSE runs after unarise
            = addDataCon case_bndr dataCon (map StgVarArg args') env1
            | otherwise
            = env1
            -- see Note [Case 2: CSEing case binders]
          rhs' = stgCseExpr env2 rhs
      in GenStgAlt (DataAlt dataCon) args' rhs'
stgCseAlt env _ _ g@GenStgAlt{alt_con=_, alt_bndrs=args, alt_rhs=rhs}
    = let (env1, args') = substBndrs env args
          rhs' = stgCseExpr env1 rhs
      in g {alt_bndrs=args', alt_rhs=rhs'}

-- Bindings
stgCseBind :: CseEnv -> InStgBinding -> (Maybe OutStgBinding, CseEnv)
stgCseBind env (StgNonRec b e)
    = let (env1, b') = substBndr env b
      in case stgCseRhs env1 b' e of
        (Nothing,      env2) -> (Nothing,                env2)
        (Just (b2,e'), env2) -> (Just (StgNonRec b2 e'), env2)
stgCseBind env (StgRec pairs)
    = let (env1, pairs1) = substPairs env pairs
      in case stgCsePairs env1 pairs1 of
        ([],     env2) -> (Nothing, env2)
        (pairs2, env2) -> (Just (StgRec pairs2), env2)

stgCsePairs :: CseEnv -> [(OutId, InStgRhs)] -> ([(OutId, OutStgRhs)], CseEnv)
stgCsePairs env [] = ([], env)
stgCsePairs env0 ((b,e):pairs)
  = let (pairMB, env1) = stgCseRhs env0 b e
        (pairs', env2) = stgCsePairs env1 pairs
    in (pairMB `mbCons` pairs', env2)
  where
    mbCons = maybe id (:)

-- The RHS of a binding.
-- If it is a constructor application, either short-cut it or extend the environment
stgCseRhs :: CseEnv -> OutId -> InStgRhs -> (Maybe (OutId, OutStgRhs), CseEnv)
stgCseRhs env bndr (StgRhsCon ccs dataCon mu ticks args typ)
    | Just other_bndr <- envLookup dataCon args' env
    , not (isWeakLoopBreaker (idOccInfo bndr)) -- See Note [Care with loop breakers]
    = let env' = addSubst bndr other_bndr env
      in (Nothing, env')
    | otherwise
    = let env' = addDataCon bndr dataCon args' env
            -- see Note [Case 1: CSEing allocated closures]
          pair = (bndr, StgRhsCon ccs dataCon mu ticks args' typ)
      in (Just pair, env')
  where args' = substArgs env args

stgCseRhs env bndr (StgRhsClosure ext ccs upd args body typ)
    = let (env1, args') = substBndrs env args
          env2 = forgetCse env1 -- See Note [Free variables of an StgClosure]
          body' = stgCseExpr env2 body
      in (Just (substVar env bndr, StgRhsClosure ext ccs upd args' body' typ), env)


mkStgCase :: StgExpr -> OutId -> AltType -> [StgAlt] -> StgExpr
mkStgCase scrut bndr ty alts | all isBndr alts = scrut
                             | otherwise       = StgCase scrut bndr ty alts

  where
    -- see Note [All alternatives are the binder]
    isBndr GenStgAlt{alt_con=_,alt_bndrs=_,alt_rhs=StgApp f []} = f == bndr
    isBndr _                                                    = False


{- Note [Care with loop breakers]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When doing CSE on a letrec we must be careful about loop
breakers.  Consider
  rec { y = K z
      ; z = K z }
Now if, somehow (and wrongly)), y and z are both marked as
loop-breakers, we do *not* want to drop the (z = K z) binding
in favour of a substitution (z :-> y).

I think this bug will only show up if the loop-breaker-ness is done
wrongly (itself a bug), but it still seems better to do the right
thing regardless.
-}

-- Utilities

-- | This function short-cuts let-bindings that are now obsolete
mkStgLet :: (a -> b -> b) -> Maybe a -> b -> b
mkStgLet _      Nothing      body = body
mkStgLet stgLet (Just binds) body = stgLet binds body


{-
Note [All alternatives are the binder]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

When all alternatives simply refer to the case binder, then we do not have
to bother with the case expression at all (#13588). CoreSTG does this as well,
but sometimes, types get into the way:

    newtype T = MkT Int
    f :: (Int, Int) -> (T, Int)
    f (x, y) = (MkT x, y)

Core cannot just turn this into

    f p = p

as this would not be well-typed. But to STG, where MkT is no longer in the way,
we can.

Note [Trivial case scrutinee]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We want to be able to CSE nested reconstruction of constructors as in

    nested :: Either Int (Either Int a) -> Either Bool (Either Bool a)
    nested (Right (Right v)) = Right (Right v)
    nested _                 = Left True

We want the RHS of the first branch to be just the original argument.
The RHS of 'nested' will look like
    case x of r1
      Right a -> case a of r2
              Right b -> let v = Right b
                         in Right v
Then:
* We create the ce_conAppMap [Right a :-> r1, Right b :-> r2].
* When we encounter v = Right b, we'll drop the binding and extend
  the substitution with [v :-> r2]
* But now when we see (Right v), we'll substitute to get (Right r2)...and
  fail to find that in the ce_conAppMap!

Solution:

* When passing (case x of bndr { alts }), where 'x' is a variable, we
  add [bndr :-> x] to the ce_bndrMap.  In our example the ce_bndrMap will
  be [r1 :-> x, r2 :-> a]. This is done in addTrivCaseBndr.

* Before doing the /lookup/ in ce_conAppMap, we "normalise" the
  arguments with the ce_bndrMap.  In our example, we normalise
  (Right r2) to (Right a), and then find it in the map.  Normalisation
  is done by normaliseConArgs.

* Similarly before /inserting/ in ce_conAppMap, we normalise the arguments.
  This is a bit more subtle. Suppose we have
       case x of y
         DEFAULT -> let a = Just y
                    let b = Just y
                    in ...
  We'll have [y :-> x] in the ce_bndrMap.  When looking up (Just y) in
  the map, we'll normalise it to (Just x).  So we'd better normalise
  the (Just y) in the defn of 'a', before inserting it!

* When inserting into cs_bndrMap, we must normalise that too!
      case x of y
        DEFAULT -> case y of z
                      DEFAULT -> ...
  We want the cs_bndrMap to be [y :-> x, z :-> x]!
  Hence the call to normaliseId in addTrivCaseBinder.

All this is a bit tricky.  Why does it not occur for the Core version
of CSE?  See Note [CSE for bindings] in GHC.Core.Opt.CSE.  The reason
is this: in Core CSE we augment the /main substitution/ with [y :-> x]
etc, so as a side consequence we transform
    case x of y       ===>    case x of y
      pat -> ...y...             pat -> ...x...
That is, the /exact reverse/ of the binder-swap transformation done by
the occurrence analyser.  However, it's easy for CSE to do on-the-fly,
and it completely solves the above tricky problem, using only two maps:
the main reverse-map, and the substitution.  The occurrence analyser
puts it back the way it should be, the next time it runs.

However in STG there is no occurrence analyser, and we don't want to
require another pass.  So the ce_bndrMap is a little swizzle that we
apply just when manipulating the ce_conAppMap, but that does not
affect the output program.


Note [Free variables of an StgClosure]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
StgClosures (function and thunks) have an explicit list of free variables:

foo [x] =
    let not_a_free_var = Left [x]
    let a_free_var = Right [x]
    let closure = \[x a_free_var] -> \[y] -> bar y (Left [x]) a_free_var
    in closure

If we were to CSE `Left [x]` in the body of `closure` with `not_a_free_var`,
then the list of free variables would be wrong, so for now, we do not CSE
across such a closure, simply because I (Joachim) was not sure about possible
knock-on effects. If deemed safe and worth the slight code complication of
re-calculating this list during or after this pass, this can surely be done.
-}
