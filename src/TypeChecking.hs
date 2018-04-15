{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE ViewPatterns      #-}
{-# OPTIONS_GHC -Wall          #-}

module TypeChecking where

import           Bound
import           Bound.Scope
import           Control.Applicative ((<|>))
import           Control.Lens ((<&>), view, (%~), (<>~))
import           Control.Monad.State
import           Control.Monad.Reader
import           Control.Monad.Trans.Except
import           Data.Bifunctor
import           Data.Bool (bool)
import           Data.Foldable (for_)
import           Data.List (nub, intercalate)
import           Data.Map (Map)
import qualified Data.Map as M
import           Data.Monoid ((<>), First (..))
import qualified Data.Set as S
import           Data.Traversable (for)
import           Prelude hiding (exp)
import           Types
import           Utils


type Placeholder = Reader (Pred -> Exp VName)


unify :: Type -> Type -> TI ()
unify t1 t2 = do
  s  <- view tiSubst <$> get
  s' <- mgu (sub s t1) (sub s t2)
  modify $ tiSubst <>~ s'
  pure ()


newVName :: (Int -> a) -> TI a
newVName f = do
  n <- view tiVNames <$> get
  modify $ tiVNames %~ (+1)
  pure $ f n


newTyVar :: Kind -> TI Type
newTyVar k = do
  n <- view tiTNames <$> get
  modify $ tiTNames %~ (+1)
  pure . TVar . flip TFreshName k $ letters !! n


freshInst :: VName -> Scheme -> TI (Qual Type, Placeholder (Exp VName))
freshInst n (Scheme vars t) = do
  nvars <- traverse newTyVar $ fmap tKind vars
  let subst = Subst $ M.fromList (zip vars nvars)
      t'@(qs :=> _) = sub subst t
  pure (t', liftPlaceholders n qs)


liftPlaceholders
    :: VName
    -> [Pred]
    -> Placeholder (Exp VName)
liftPlaceholders name ps = do
  f <- ask
  let dicts = fmap f ps
  pure $ foldl (:@) (V name) dicts


mgu :: Type -> Type -> TI Subst
mgu (l :@@ r) (l' :@@ r') = do
  s1 <- mgu l l'
  s2 <- mgu (sub s1 r) (sub s1 r')
  pure $ s1 <> s2
mgu (TCon a) (TCon b)
  | a == b  = pure mempty
mgu (TVar u) t  = varBind u t
mgu t (TVar u)  = varBind u t
mgu t1 t2       = throwE $
  mconcat
    [ "types don't unify: '"
    , show t1
    , "' vs '"
    , show t2
    , "'"
    ]


varBind :: TName -> Type -> TI Subst
varBind u t
  | t == TVar u = pure mempty
  | S.member u (free t) = throwE
      $ mconcat
        [ "occurs check: '"
        , show u
        , "' vs '"
        , show t
        , "'"
        ]
  | otherwise = do
      k <- kind t
      when (k /= tKind u) $ throwE "kind unification fails"
      pure $ Subst [(u, t)]


splatter :: Monad f => c -> Scope b f c -> f c
splatter = splat pure . const . pure


inferLit :: Lit -> Type
inferLit (LitInt _)    = TInt
inferLit (LitString _) = TString


infer
    :: (Int -> VName)
    -> SymTable VName
    -> Exp VName
    -> TI ([Pred], Type, Placeholder (Exp VName))
infer f env (Assert e t) = do
  (p1, t1, h1) <- infer f env e
  unify t t1
  s <- view tiSubst <$> get
  pure (sub s p1, t, Assert <$> h1 <*> pure t)
infer _ (SymTable env) (V a) =
  case M.lookup a env of
    Nothing -> throwE $ "unbound variable: '" <> show a <> "'"
    Just sigma -> do
      (ps :=> x, h) <- freshInst a sigma
      pure (ps, x, h)
infer f env (Let n e1 b) = do
  name <- newVName f
  let e2 = splatter name b
  (p1, t1, h1) <- infer f env e1
  let t'   = generalize env $ p1 :=> t1
      env' = SymTable $ M.insert name t' $ unSymTable env
  (p2, t2, h2) <- infer f env' e2
  pure (p2, t2, let_ <$> pure n <*> h1 <*> h2)
infer _ _ h@(Lit l) = pure (mempty, inferLit l, pure h)

-- TODO(sandy): maybe this is wrong?
infer f env (LCon a) = infer f env (V a)

infer f env (Case e ps) = do
  t <- newTyVar KStar
  (p1, te, h1) <- infer f env e
  (p2, tps, h2) <- fmap unzip3 $ for ps $ \(pat, pexp) -> do
    (as, ts) <- inferPattern env pat
    unify te ts
    let env' = SymTable $ M.fromList (as <&> \(i :>: x) -> (i, x))
                       <> unSymTable env
        pexp' = instantiate V pexp
    (p2, tp, h2) <- infer f env' pexp'
    unify t tp
    pure (p2, tp, (,) <$> pure pat <*> h2)

  for_ (zip tps $ tail tps) $ uncurry $ flip unify

  pure (p1 <> join p2, t, case_ <$> h1 <*> sequence h2)

infer f (SymTable env) (Lam n x) = do
  name <- newVName f
  tv <- newTyVar KStar
  let env' = SymTable $ env <> [(name, mkScheme tv)]
      e = splatter name x
  (p1, t1, h1) <- infer f env' e
  pure (p1, TArr tv t1, lam <$> pure n <*> h1)

infer f env exp@(e1 :@ e2) =
  do
    tv <- newTyVar KStar
    (p1, t1, h1) <- infer f env e1
    (p2, t2, h2) <- infer f env e2
    unify t1 $ TArr t2 tv
    pure (p1 <> p2, tv, (:@) <$> h1 <*> h2)
  `catchE` \e -> throwE $
    mconcat
      [ e
      , "\n in "
      , show exp
      -- , "\n\ncontext: \n"
      -- , foldMap ((<> "\n") . show) . M.assocs $ unSymTable env
      ]


inferPattern :: SymTable VName -> Pat -> TI ([Assump Scheme], Type)
inferPattern _ (PLit l) = do
  pure (mempty, inferLit l)
inferPattern _ PWildcard = do
  ty <- newTyVar KStar
  pure (mempty, ty)
inferPattern _ (PVar x) = do
  ty <- newTyVar KStar
  pure (pure $ x :>: mkScheme ty, ty)
inferPattern st (PAs x p) = do
  (as, t) <- inferPattern st p
  pure (x :>: mkScheme t : as, t)
inferPattern st (PCon c ps) = do
  t <- newTyVar KStar
  (as, ts) <- first join . unzip <$> for ps (inferPattern st)
  -- this is gross! there is a bug here if the type constructor has constraints
  -- on it
  (_, ct, _) <- infer (error "unused") st $ V c
  unify ct $ foldr (:->) t ts
  pure (as, t)


typeInference
    :: ClassEnv
    -> Map VName Scheme
    -> Exp VName
    -> TI (Qual Type, Exp VName)
typeInference cenv env e = do
  (ps, t, h) <- infer (VName . ("!!!v" <>) . show) (SymTable env) e
  s <- view tiSubst <$> get
  zs <- traverse (discharge cenv) $ sub (flatten s) ps
  let (s', ps', _, _) = mconcat zs
      s'' = flatten $ s <> s'
      (ps'' :=> t') = sub s'' $ ps' :=> t
      t'' = nub ps'' :=> t'
  _ <- errorAmbiguous t''
  pure (t'', runReader h $ V . VName . show . sub s'')


flatten :: Subst -> Subst
flatten (Subst x) = fix $ \(Subst final) ->
  Subst $ M.fromList $ M.assocs x <&> \(a, b) -> (a,) $
    sub (Subst final) $ case b of
      TVar n -> maybe (TVar n) id $ M.lookup n final
      z      -> z


generalize :: SymTable a -> Qual Type -> Scheme
generalize env t =
  Scheme (S.toList $ free t S.\\ free env) t


generalizing :: SymTable a -> Qual Type -> Scheme
generalizing env t =
  Scheme (S.toList $ free t S.\\ free env) t


normalizeType :: Qual Type -> Qual Type
normalizeType = schemeType . normalize . Scheme mempty


normalize :: Scheme -> Scheme
normalize (Scheme _ body) =
    Scheme (fmap snd ord) $ normqual body
  where
    ord = zip (nub . S.toList $ free body) letters <&> \(old, l) ->
      (old, TName l $ tKind old)
    normqual (xs :=> zs) =
      fmap (\(IsInst c t) -> IsInst c $ normtype t) xs :=> normtype zs

    normtype (TCon a)    = TCon a
    normtype (a :@@ b)   = normtype a :@@ normtype b
    normtype (TVar a)    =
      case lookup a ord of
        Just x  -> TVar $ TName (unTName x) (tKind x)
        Nothing -> error "type variable not in signature"


discharge
    :: ClassEnv
    -> Pred
    -> TI ( Subst
          , [Pred]
          , Map Pred (Exp VName)
          , [Assump (Qual Type)]
          )
discharge cenv p = do
  x <- for (getQuals cenv) $ \(a :=> b) -> do
    s <- (fmap (a,) <$> match' b p) <|> pure Nothing
    pure $ First s
  case getFirst $ mconcat x of
    Just (ps, s) ->
      fmap mconcat $ traverse (discharge cenv) $ sub s $ ps
    Nothing -> do
      pure $ (mempty, pure p, mempty, mempty)


errorAmbiguous :: Qual Type -> TI (Qual Type)
errorAmbiguous (t@(a :=> b)) = do
  let amb = S.toList $ free a S.\\ free b
  when (amb /= mempty) . throwE $ mconcat
    [ "the type variable"
    , bool "" "s" $ null amb
    , " '"
    , intercalate "', '" $ fmap show amb
    , "' "
    , bool "is" "are" $ null amb
    , " ambiguous\n"
    , "in the type '"
    , show t
    , "'\n"
    ]
  pure t


-- | Unlike 'unify', the order of the paremeters here matters.
match :: Type -> Type -> TI Subst
match (l :@@ r) (l' :@@ r') = do
  sl <- match l l'
  sr <- match r r'
  pure . Subst $ unSubst sl <> unSubst sr
match (TVar u) t  = pure $ Subst [(u, t)]
match (TCon tc1) (TCon tc2)
  | tc1 == tc2    = pure mempty
match t1 t2       = throwE $ mconcat
  [ "types do not match: '"
  , show t1
  , "' vs '"
  , show t2
  , "'\n"
  ]

match' :: Pred -> Pred -> TI (Maybe Subst)
match' (IsInst a b) (IsInst a' b')
  | a /= a'   = pure Nothing
  | otherwise = Just <$> match b b'

