module Nuko.Typer.Infer.Expr (
  inferExpr,
  checkExpr,
) where

import Relude

import Nuko.Names               (Name, Path (..), ValName)
import Nuko.Report.Range        (Range (..), getPos)
import Nuko.Resolver.Tree       ()
import Nuko.Tree                (Block (..), Re, Tc, Var (..))
import Nuko.Tree.Expr           (Expr (..))
import Nuko.Typer.Env
import Nuko.Typer.Error         (TypeError (..))
import Nuko.Typer.Infer.Literal (boolTy, inferLit)
import Nuko.Typer.Infer.Pat     (inferPat)
import Nuko.Typer.Infer.Type    (inferClosedTy)
import Nuko.Typer.Match         (checkPatterns)
import Nuko.Typer.Tree          ()
import Nuko.Typer.Types         (Relation (..), TTy (..), derefTy, evaluate,
                                 isError, quote)
import Nuko.Typer.Unify         (destructFun, unify)

import Control.Monad.Reader     (foldM)
import Data.List.NonEmpty       ((<|))
import Data.Traversable         (for)
import Lens.Micro.Platform      (view)

import Data.HashMap.Strict      qualified as HashMap
import Nuko.Typer.Error.Extract (Tracker (InFunApp), track)

inferBlock :: MonadTyper m => Block Re -> m (Block Tc, TTy 'Virtual)
inferBlock = \case
  BlBind expr rest -> do
    (resExpr,       _) <- inferExpr expr
    (resBlock, resTy') <- inferBlock rest
    pure (BlBind resExpr resBlock, resTy')
  BlVar var rest   -> do
    ((patRes, patTy), bindings) <- inferPat var.pat
    (exprRes, resPatTy) <- checkExpr var.val patTy
    when (not $ isError resPatTy) (checkPatterns (getPos var.pat) (one patRes))
    (resBlock, resTy') <- addLocals bindings (inferBlock rest)
    pure (BlVar (Var patRes exprRes var.ext) resBlock, resTy')
  BlEnd expr       -> do
    (resExpr, resTy) <- runInst $ inferExpr expr
    pure (BlEnd resExpr, resTy)

checkExpr :: MonadTyper m => Expr Re -> TTy 'Virtual -> m (Expr Tc, TTy 'Virtual)
checkExpr expr tty = case (expr, tty) of
  (_, TyForall _ f) -> do
    ctxLvl <- view seScope
    checkExpr expr (f (TyVar ctxLvl))
  (Lam exprPat expr' e, TyFun argTy retTy) -> do
    ((patRes, patTy), bindings) <- inferPat exprPat
    resTy <- unify (getPos exprPat) patTy argTy
    when (not $ isError resTy) (checkPatterns (getPos exprPat) (one patRes))
    (exprRes, bodyResTy) <- addLocals bindings (checkExpr expr' retTy)
    pure (Lam patRes exprRes (quote 0 (TyFun resTy bodyResTy), e), (TyFun resTy bodyResTy))
  _ -> do
    (resExpr, inferedTy) <- inferExpr expr
    instTy <- eagerInstantiate inferedTy
    retTy <- unify (getPos expr) instTy tty
    pure (resExpr, retTy)

applyExpr :: MonadTyper m => Range -> TTy 'Virtual -> Expr Re -> m (Expr Tc, TTy 'Virtual)
applyExpr range fnTy expr = do
  (argTy, resTy) <- destructFun range fnTy
  (argRes, _) <- checkExpr expr argTy
  pure (argRes, resTy)

accApplyExpr :: MonadTyper m => Range -> (Int, NonEmpty (Expr Tc), TTy 'Virtual) -> Expr Re -> m (Int,NonEmpty (Expr Tc), TTy 'Virtual)
accApplyExpr range (place, exprs, fnTy) expr = do
  (resExpr, tty) <- track (InFunApp range place (getPos expr)) $ applyExpr range fnTy expr
  pure (place + 1, resExpr <| exprs, tty)

inferExpr :: MonadTyper m => Expr Re -> m (Expr Tc, TTy 'Virtual)
inferExpr = \case
  Lit lit extension -> do
    (resLit, resTy) <- inferLit lit
    pure (Lit resLit extension, resTy)
  Lower path _ -> do
    ty <- case path of
      Local _ path' -> getLocal path'
      Full _ qual   -> evaluate [] . fst <$> getTy tsVars qual
    pure (Lower path (quote 0 ty), ty)
  Upper path _ -> do
    qualified <- qualifyPath path
    (consTy, _) <- getTy tsConstructors qualified
    pure (Upper path consTy, evaluate [] consTy)
  Ann expr ty extension -> do
    (resTy, _) <- inferClosedTy ty
    (exprRes, resTy') <- checkExpr expr resTy
    pure (Ann exprRes (quote 0 resTy) extension, resTy')
  Block block extension -> do
    (blockRes, resTy) <- inferBlock block
    pure (Block blockRes (quote 0 resTy, extension), resTy)
  If con if' else' extension -> do
    (conRes, conTy) <- inferExpr con
    _ <- unify (getPos con) conTy boolTy
    (ifRes, ifTy)  <- runInst $ inferExpr if'
    (elseRes, ifResTy) <- checkExpr else' ifTy
    pure (If conRes ifRes elseRes (quote 0 ifTy, extension), ifResTy)
  Match scrut cas range -> do
    (scrutRes, nonInstScrutTy) <- inferExpr scrut
    scrutTy <- eagerInstantiate nonInstScrutTy
    resTy <- genTyHole
    patError <- newIORef False

    casesRes <- for cas $ \(casePat, expr) ->  do
      ((resPat, patTy), bindings) <- inferPat casePat
      scrutResTy <- unify (getPos resPat) patTy scrutTy
      when (isError scrutResTy) (writeIORef patError True)
      resExpr <- addLocals bindings (checkExpr expr resTy)
      pure (resPat, resExpr)

    let isErrored = any isError $ (snd . snd) <$> casesRes
    let patsMatch = (second fst) <$> casesRes

    isPatErrored <- readIORef patError
    when (not isPatErrored) (checkPatterns range (fst <$> casesRes))

    if (not isErrored) then do
      let resDeref = derefTy resTy
      pure (Match scrutRes patsMatch (quote 0 resDeref, range), derefTy resTy)
    else do
      pure (Match scrutRes patsMatch (TyErr, range), TyErr)

  Lam binderPat expr extension -> do
    ((resPat, patTy), bindings) <- inferPat binderPat
    when (not $ isError patTy) (checkPatterns (getPos binderPat) (one (resPat)))
    (resExpr, exprTy) <- runInst $ addLocals bindings (inferExpr expr)
    pure (Lam resPat resExpr (quote 0 (TyFun patTy exprTy), extension), TyFun patTy exprTy)
  App expr (x :| xs) extension -> do
    (fnExpr, fnTy) <- inferExpr expr
    let fnRange = getPos expr
    (argExpr, fnResTy) <- track (InFunApp fnRange 1 (getPos x)) $ applyExpr fnRange fnTy x
    (_, resArgs, resTy) <- foldM (accApplyExpr fnRange) (2, one argExpr, fnResTy) xs
    pure (App fnExpr resArgs (quote 0 resTy, extension), resTy)
  Field expr field extension -> do
    -- TODO: Probably will have problems with eager instantiation
    (resExpr, resTy) <- inferExpr expr
    (argFieldTy, resFieldTy) <- destructFun (getPos field) =<< getFieldByTy field resTy
    _ <- unify (getPos expr) argFieldTy resTy
    pure (Field resExpr field (quote 0 resFieldTy, extension), resFieldTy)

-- TODO: If the type is private and it's not in the current namespace, we have to thrown
-- an error. It would cause problems in the hot reloading.
getFieldByTy :: MonadTyper m => Name ValName -> TTy 'Virtual -> m (TTy 'Virtual)
getFieldByTy field = \case
  TyApp _ f _ -> getFieldByTy field f
  TyIdent p   -> do
    res <- getTy tsTypeFields p
    case HashMap.lookup field res of
      Just res' -> pure (evaluate [] res'._fiResultType)
      Nothing   -> endDiagnostic (CannotInferField (getPos field)) (getPos field)
  _ -> endDiagnostic (CannotInferField (getPos field)) (getPos field)
