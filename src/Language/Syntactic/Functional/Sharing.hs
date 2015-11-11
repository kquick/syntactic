{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}

#ifndef MIN_VERSION_GLASGOW_HASKELL
#define MIN_VERSION_GLASGOW_HASKELL(a,b,c,d) 0
#endif
  -- MIN_VERSION_GLASGOW_HASKELL was introduced in GHC 7.10

-- | Simple code motion transformation performing common sub-expression
-- elimination and variable hoisting. Note that the implementation is very
-- inefficient.
--
-- The code is based on an implementation by Gergely Dévai.

module Language.Syntactic.Functional.Sharing
    ( -- * Interface
      InjDict (..)
    , CodeMotionInterface (..)
    , defaultInterface
    , defaultInterfaceT
      -- * Code motion
    , codeMotion
    ) where



#if MIN_VERSION_GLASGOW_HASKELL(7,10,0,0)
#else
import Control.Applicative
#endif
import Control.Monad.State
import Data.Maybe (isNothing)
import Data.Set (Set)
import qualified Data.Set as Set

import Language.Syntactic
import Language.Syntactic.Functional



--------------------------------------------------------------------------------
-- * Interface
--------------------------------------------------------------------------------

-- | Interface for injecting binding constructs
data InjDict sym a b = InjDict
    { injVariable :: Name -> sym (Full a)
        -- ^ Inject a variable
    , injLambda   :: Name -> sym (b :-> Full (a -> b))
        -- ^ Inject a lambda
    , injLet      :: sym (a :-> (a -> b) :-> Full b)
        -- ^ Inject a "let" symbol
    }

-- | Code motion interface
data CodeMotionInterface sym = Interface
    { mkInjDict   :: forall a b . ASTF sym a -> ASTF sym b -> Maybe (InjDict sym a b)
        -- ^ Try to construct an 'InjDict'. The first argument is the expression
        -- to be shared, and the second argument the expression in which it will
        -- be shared. This function can be used to transfer information (e.g.
        -- from static analysis) from the shared expression to the introduced
        -- variable.
    , castExprCM  :: forall a b . ASTF sym a -> ASTF sym b -> Maybe (ASTF sym b)
        -- ^ Try to type cast an expression. The first argument is the
        -- expression to cast. The second argument can be used to construct a
        -- witness to support the casting. The resulting expression (if any)
        -- should be equal to the first argument.
    , hoistOver   :: forall c. ASTF sym c -> Bool
        -- ^ Whether a sub-expression can be hoisted over the given expression
    }

-- | Default 'CodeMotionInterface' for domains of the form
-- @`Typed` (... `:+:` `Binding` `:+:` ...)@.
defaultInterface :: forall sym symT
    .  ( Binding :<: sym
       , Let     :<: sym
       , symT ~ Typed sym
       )
    => (forall a b . ASTF symT a -> ASTF symT b -> Bool)
         -- ^ Can the expression represented by the first argument be shared in
         -- the second argument?
    -> (forall a . ASTF symT a -> Bool)  -- ^ Can we hoist over this expression?
    -> CodeMotionInterface symT
defaultInterface sharable hoistOver = Interface {..}
  where
    mkInjDict :: ASTF symT a -> ASTF symT b -> Maybe (InjDict symT a b)
    mkInjDict a b | not (sharable a b) = Nothing
    mkInjDict a b =
        simpleMatch
          (\(Typed _) _ -> simpleMatch
            (\(Typed _) _ ->
              let injVariable = Typed . inj . Var
                  injLambda   = Typed . inj . Lam
                  injLet      = Typed $ inj Let
              in  Just InjDict {..}
            ) b
          ) a

    castExprCM = castExpr

-- | Default 'CodeMotionInterface' for domains of the form
-- @`Typed` (... `:+:` `BindingT` `:+:` ...)@.
defaultInterfaceT :: forall sym symT
    .  ( BindingT :<: sym
       , Let      :<: sym
       , symT ~ Typed sym
       )
    => (forall a b . ASTF symT a -> ASTF symT b -> Bool)
         -- ^ Can the expression represented by the first argument be shared in
         -- the second argument?
    -> (forall a . ASTF symT a -> Bool)  -- ^ Can we hoist over this expression?
    -> CodeMotionInterface symT
defaultInterfaceT sharable hoistOver = Interface {..}
  where
    mkInjDict :: ASTF symT a -> ASTF symT b -> Maybe (InjDict symT a b)
    mkInjDict a b | not (sharable a b) = Nothing
    mkInjDict a b =
        simpleMatch
          (\(Typed _) _ -> simpleMatch
            (\(Typed _) _ ->
              let injVariable = Typed . inj . VarT
                  injLambda   = Typed . inj . LamT
                  injLet      = Typed $ inj Let
              in  Just InjDict {..}
            ) b
          ) a

    castExprCM = castExpr



--------------------------------------------------------------------------------
-- * Code motion
--------------------------------------------------------------------------------

-- | Substituting a sub-expression. Assumes no variable capturing in the
-- expressions involved.
substitute :: forall sym a b
    .  (Equality sym, BindingDomain sym)
    => CodeMotionInterface sym
    -> ASTF sym a  -- ^ Sub-expression to be replaced
    -> ASTF sym a  -- ^ Replacing sub-expression
    -> ASTF sym b  -- ^ Whole expression
    -> ASTF sym b
substitute iface x y a
    | Just y' <- castExprCM iface y a, alphaEq x a = y'
    | otherwise = subst a
  where
    subst :: AST sym c -> AST sym c
    subst (f :$ a) = subst f :$ substitute iface x y a
    subst a = a
  -- Note: Since `codeMotion` only uses `substitute` to replace sub-expressions
  -- with fresh variables, there's no risk of capturing.

-- | Count the number of occurrences of a sub-expression
count :: forall sym a b
    .  (Equality sym, BindingDomain sym)
    => ASTF sym a  -- ^ Expression to count
    -> ASTF sym b  -- ^ Expression to count in
    -> Int
count a b
    | alphaEq a b = 1
    | otherwise   = cnt b
  where
    cnt :: AST sym c -> Int
    cnt (f :$ b) = cnt f + count a b
    cnt _        = 0

-- | Environment for the expression in the 'choose' function
data Env sym = Env
    { inLambda :: Bool  -- ^ Whether the current expression is inside a lambda
    , counter  :: EF (AST sym) -> Int
        -- ^ Counting the number of occurrences of an expression in the
        -- environment
    , dependencies :: Set Name
        -- ^ The set of variables that are not allowed to occur in the chosen
        -- expression
    }

-- | Checks whether a sub-expression in a given environment can be lifted out
liftable :: BindingDomain sym => Env sym -> ASTF sym a -> Bool
liftable env a = independent && isNothing (prVar a) && heuristic
      -- Lifting dependent expressions is semantically incorrect. Lifting
      -- variables would cause `codeMotion` to loop.
  where
    independent = Set.null $ Set.intersection (freeVars a) (dependencies env)
    heuristic   = inLambda env || (counter env (EF a) > 1)

-- | A sub-expression chosen to be shared together with an evidence that it can
-- actually be shared in the whole expression under consideration
data Chosen sym a
  where
    Chosen :: InjDict sym b a -> ASTF sym b -> Chosen sym a

-- | Choose a sub-expression to share
choose :: forall sym a
    .  (Equality sym, BindingDomain sym)
    => CodeMotionInterface sym
    -> ASTF sym a
    -> Maybe (Chosen sym a)
choose iface a = chooseEnvSub initEnv a
  where
    initEnv = Env
        { inLambda     = False
        , counter      = \(EF b) -> count b a
        , dependencies = Set.empty
        }

    chooseEnv :: Env sym -> ASTF sym b -> Maybe (Chosen sym a)
    chooseEnv env b
        | liftable env b
        , Just id <- mkInjDict iface b a
        = Just $ Chosen id b
    chooseEnv env b
        | hoistOver iface b = chooseEnvSub env b
        | otherwise         = Nothing

    -- | Like 'chooseEnv', but does not consider the top expression for sharing
    chooseEnvSub :: Env sym -> AST sym b -> Maybe (Chosen sym a)
    chooseEnvSub env (Sym lam :$ b)
        | Just v <- prLam lam
        = chooseEnv (env' v) b
      where
        env' v = env
            { inLambda     = True
            , dependencies = Set.insert v (dependencies env)
            }
    chooseEnvSub env (s :$ b) = chooseEnvSub env s `mplus` chooseEnv env b
    chooseEnvSub _ _ = Nothing

codeMotionM :: forall sym m a
    .  ( Equality sym
       , BindingDomain sym
       , MonadState Name m
       )
    => CodeMotionInterface sym
    -> ASTF sym a
    -> m (ASTF sym a)
codeMotionM iface a
    | Just (Chosen id b) <- choose iface a = share id b
    | otherwise = descend a
  where
    share :: InjDict sym b a -> ASTF sym b -> m (ASTF sym a)
    share id b = do
        b' <- codeMotionM iface b
        v  <- get; put (v+1)
        let x = Sym (injVariable id v)
        body <- codeMotionM iface $ substitute iface b x a
        return
            $  Sym (injLet id)
            :$ b'
            :$ (Sym (injLambda id v) :$ body)

    descend :: AST sym b -> m (AST sym b)
    descend (f :$ a) = (:$) <$> descend f <*> codeMotionM iface a
    descend a        = return a

-- | Perform common sub-expression elimination and variable hoisting
codeMotion :: forall sym m a
    .  ( Equality sym
       , BindingDomain sym
       )
    => CodeMotionInterface sym
    -> ASTF sym a
    -> ASTF sym a
codeMotion iface a = flip evalState maxVar $ codeMotionM iface a
  where
    maxVar = succ $ Set.findMax $ allVars a
