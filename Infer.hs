{-# LANGUAGE TupleSections #-}
module Infer where

import Data.List(intersperse)
import Data.Functor((<$>))
import Control.Applicative((<*>))
import Data.Functor.Identity(Identity(..), runIdentity)
import Control.Monad(forM, foldM)
import Control.Monad.Trans(lift)
import Control.Monad.Trans.State(StateT, evalStateT, get, put)
import Control.Monad.Trans.Reader(ReaderT, runReaderT, ask, local, mapReaderT)
import Control.Monad.Trans.Writer(WriterT, runWriterT, tell, listen)
import Control.Monad.Trans.Either(EitherT, runEitherT, left, hoistEither)
import Control.Arrow(first)
import qualified Data.Map.Lazy as Map

import Types

import Debug.Trace
traceInfer s x = traceShow (s ++ show x) x
traceInfer _ x = x

type JSTypeEnv = TypeEnv JSConsType
type JSTypeSig = TypeSig JSConsType
type JSTSubst = TSubst JSConsType
type JSTypeError = TypeError JSConsType
data NameSupply = NameSupply { maxName :: Name }

emptyNameSupply :: NameSupply
emptyNameSupply = NameSupply { maxName = 0 }

data Env = Env { typeEnv :: JSTypeEnv
               , funcReturnType :: Maybe JSType }

emptyEnv :: Env
emptyEnv = Env { typeEnv = emptyTEnv
               , funcReturnType = Nothing }

-- | An inference result with internal context.
-- | ReaderT JSTypeEnv - type signatures must be propogated only inward towards nested expressions
-- | WriterT JSTSubst - results of unification, stored in a TSubst, must be propogated outwards from nested expressions and composed with the current subst map
-- | StateT NameSupply - stateful "counter" used for naming fresh type variables
-- | EitherT TypeError - failure at any point shortcuts the result returning a Left TypeError instead.
type Infer a = ReaderT Env (WriterT JSTSubst (StateT NameSupply (EitherT JSTypeError Identity))) a

runInfer :: Infer a -> Either JSTypeError a
runInfer = runIdentity 
           . runEitherT 
           . flip evalStateT emptyNameSupply
           . fmap fst 
           . runWriterT 
           . flip runReaderT emptyEnv

-- TODO: Change extend (in Types.hs) so that the types map always contains var -> tcons mappings, without intermediate tvars.
substStatement :: JSTSubst -> Statement (Expr JSType) -> Statement (Expr JSType)
substStatement subst stmt = f stmt
    where f :: Statement (Expr JSType) -> Statement (Expr JSType)
          f = fmap . fmap $ (fromType . substituteType' . toType)
          substituteType' x = case substituteType subst x of
                                t@(TVar _) -> if t == x then t else substituteType' t
                                TCons name ys -> TCons name $ map substituteType' ys
                                --TRow props -> TRow $ map (\(n,t) -> (n, substituteType' t)) props

typeInference :: Statement (Expr a) -> Either JSTypeError (Statement (Expr JSType))
typeInference stmt = runIdentity 
                     . runEitherT 
                     . flip evalStateT emptyNameSupply
                     . fmap s'
                     . runWriterT 
                     . flip runReaderT emptyEnv
                     $ inferStatement stmt
    where s' :: (Statement (Expr JSType), JSTSubst) -> Statement (Expr JSType)
          s' (t, s) = substStatement s t


typeFail :: JSTypeError -> Infer a
typeFail = lift . lift . lift . left

fresh :: Infer Name
fresh = do ns <- lift . lift $ get
           let newName = 1 + maxName ns
           lift . lift . put $ ns { maxName = newName }
           return newName

askTypeEnv :: Infer JSTypeEnv
askTypeEnv = typeEnv <$> ask

withTypeEnv :: (JSTypeEnv -> JSTypeEnv) -> Infer a -> Infer a
withTypeEnv f = local (\env -> env { typeEnv = f . typeEnv $ env })


listenTSubst :: Infer a -> Infer (a, JSTSubst)
listenTSubst = mapReaderT listen 

askReturnType :: Infer (Maybe JSType)
askReturnType = funcReturnType <$> ask

withReturnType :: JSType -> Infer a -> Infer a
withReturnType t = local (\env -> env { funcReturnType = Just t })

tellTSubst :: JSTSubst -> Infer ()
tellTSubst = lift . tell

runEither :: Either JSTypeError r -> Infer r
runEither = lift . lift . lift . hoistEither


returnSubstType :: JSType -> JSTSubst -> Infer JSType
returnSubstType t subst  = do
    tellTSubst subst
    return . fromType . substituteType subst . toType $ t 

returnInfer :: Body (Expr JSType) -> JSType -> JSTSubst -> Infer (Expr JSType)
returnInfer b t subst = Expr b <$> returnSubstType t subst

-- TODO generalize to foldable
accumInfer :: (b -> Infer c) -> [b]  -> Infer ([c], JSTSubst)
accumInfer act es = first reverse <$> foldM (accumInfer' act) ([], idSubst) es

accumInfer' :: (b -> Infer c) -> ([c], JSTSubst) -> b -> Infer ([c], JSTSubst)
accumInfer' inferAct (ts, lastSub) argExpr = do
  (argType, newSub) <- listenTSubst $ withTypeEnv (substituteTE lastSub) (inferAct argExpr)
  return (argType : ts, newSub `compose` lastSub) 

isValue :: Expr a -> Bool
isValue (Expr body _) = 
    case body of
      LitFunc _ _ _ _ -> True
      LitArray _ -> True
      LitBoolean _ -> True
      LitNumber _ -> True
      LitRegex _ -> True
      LitString _ -> True
      LitObject _ -> True
      Var _ -> True
      _ -> False

inferExpr :: Expr a -> Infer (Expr JSType)
inferExpr (Expr body _) =
    case body of
      LitFunc name argNames varNames stmts -> inferFunc name argNames varNames stmts
      Assign lval rval -> inferAssign lval rval
      Call callee args -> inferCall callee args
      Index expr indexExpr -> inferIndex expr indexExpr
      LitArray exprs -> inferArray exprs
      LitBoolean x -> return $ Expr (LitBoolean x) JSBoolean
      LitNumber x -> return $ Expr (LitNumber x) JSNumber
      LitRegex x -> return $ Expr (LitRegex x) JSRegex
      LitString x -> return $ Expr (LitString x) JSString
      LitObject props -> inferObject props
      Property expr propName -> inferProperty expr propName
      Var name -> inferVar name

inferObject :: [(String, Expr a)] -> Infer (Expr JSType)
inferObject props = do
  let propNames = map fst props
      propExprs = map snd props
  (inferredProps, subst) <- accumInfer inferExpr propExprs
  let newBody = LitObject $ zip propNames inferredProps
      propTypes = map exprData inferredProps
  returnInfer newBody (JSObject $ zip propNames propTypes) subst


inferProperty :: Expr a -> String -> Infer (Expr JSType)
inferProperty expr propName = do
  propTypeName <- fresh
  let propType = JSTVar propTypeName
  (infExpr@(Expr _ objType), subst) <- listenTSubst $ inferExpr expr
  subst' <- runEither $ unify subst (toType objType) (toType $ JSObject [(propName, propType)])
  let finalSubst = subst' `compose` subst
  returnInfer (Property infExpr propName) propType finalSubst
 

inferIndex :: Expr a -> Expr a -> Infer (Expr JSType)
inferIndex expr indexExpr = do
  elemTypeName <- fresh
  let elemType = JSTVar elemTypeName
  (rt, rs) <- listenTSubst $ inferExpr expr
  s1 <- runEither $ unify rs (toType . exprData $ rt) (toType $ JSArray elemType)
  (lt, ls) <- listenTSubst $ withTypeEnv (substituteTE s1) $ inferExpr indexExpr
  s2 <- runEither $ unify ls (toType . exprData $ lt) (toType JSNumber)
  let finalSubst = s2 `compose` ls `compose` s1 `compose` rs
  returnInfer (Index rt lt) elemType finalSubst

inferAssign :: Expr a -> Expr a -> Infer (Expr JSType)
inferAssign lval rval = do
  (rt, rs) <- listenTSubst $ inferExpr rval
  (lt, ls) <- listenTSubst $ withTypeEnv (substituteTE rs) $ inferExpr lval
  tenv <- askTypeEnv
  -- value restriction:
  rt' <- if isValue rval
         then newInstance . traceInfer "generalized: " . generalize tenv . toType . exprData $ rt
         else return . exprData $ rt
  subst' <- runEither $ unify ls (traceInfer "RHS: " $ toType rt') (traceInfer "LHS: " $ toType . exprData $ lt)
  let finalSubst = subst' `compose` ls `compose` rs
  returnInfer (Assign lt rt) (exprData rt) finalSubst


-- newInstance tsig = (traceInfer "instantiated to: " <$> newInstance' (traceInfer "tsig: " tsig))
-- page 178
-- | instantiates a given type signature: allocates fresh variables for all the bound names and replaces them in the type
newInstance :: JSTypeSig -> Infer JSType
newInstance tsig@(TypeSig varNames t) = 
    do substList <- forM varNames $ \name -> 
                do tname <- fresh
                   return (name, TVar tname) -- TODO verify name unique in varNames
       traceInfer ("newInstance: " ++ show tsig ++ " -> ") <$> returnSubstType (fromType t) (substFromList substList)

-- | Infers a value variable expression. If the variable is assigned a type signature, instantiate it. Otherwise fail.
inferVar :: String -> Infer (Expr JSType)
inferVar name = do
  tenv <- askTypeEnv
  case Map.lookup name tenv of
--    Just tsig@(TypeSig _ (TCons JSConsFunc _)) -> Expr (Var name) <$> newInstance tsig
    Just tsig@(TypeSig _ t) -> Expr (Var name) . traceInfer varDesc <$> newInstance tsig --(TypeSig [] t)
        where varDesc = "var " ++ show name ++ " :: "
    Nothing -> typeFail $ GenericTypeError ("Unbound variable: " ++ name)
  
inferCall :: Expr a -> [Expr a] -> Infer (Expr JSType)
inferCall callee args = do
  returnTName <- fresh
  let returnTVar = JSTVar returnTName
  (infCallee:infArgs, substN) <- accumInfer inferExpr $ callee:args
  newTSubst <- flip unifyExprs' substN (JSFunc (map exprData infArgs) returnTVar) (traceInfer "callee: " $ exprData infCallee) 
  let finalSubst = newTSubst `compose` substN
  returnInfer (Call infCallee infArgs) returnTVar finalSubst 


introduceTVars :: [((String, Name), [Name])] -> TypeEnv a -> TypeEnv a
introduceTVars argNames tenv = foldr introduceVars' tenv argNames
    where introduceVars' ((argName, argTypeName), typeSigNames) = setTypeSig argName (TypeSig typeSigNames $ TVar argTypeName) 

-- don't allow variable type polymorphism - so set the type scheme bound vars to an empty list []
introduceMonomorph :: [(String, Name)] -> TypeEnv a -> TypeEnv a
introduceMonomorph argNames = introduceTVars $ map (,[]) argNames

mkJSFunc :: Name -> [Name] -> JSType
mkJSFunc returnTypeName argTypeNames = JSFunc (map JSTVar argTypeNames) (JSTVar returnTypeName)

getFuncTypeSig :: [String] -> Infer JSTypeSig
getFuncTypeSig argNames = do
  argTypeNames <- forM argNames $ const fresh
  returnInferName <- fresh
  let funcType = mkJSFunc returnInferName argTypeNames
  return . TypeSig (returnInferName:argTypeNames) $ toType funcType

consIf :: Bool -> a -> [a] -> [a]
consIf p = if p then (:) else const id

inferFunc :: Maybe String -> [String] -> [String] -> Statement (Expr a) -> Infer (Expr JSType)
inferFunc name argNames varNames stmts = do
  varTypeNames <- forM varNames $ const fresh
  argTypeNames <- forM argNames $ const fresh
  --funcTypeSig <- getFuncTypeSig argNames
  returnTypeName <- fresh
  recursionFuncTypeName <- fresh
  let --setFuncTypeSig = flip setTypeSig funcTypeSig
      funcType = mkJSFunc returnTypeName argTypeNames
      varNamesWithTypeVars = zip varNames varTypeNames
      argNamesWithTypeVars = zip argNames argTypeNames
      monotypes = argNamesWithTypeVars -- ++ varNamesWithTypeVars 
      dupeB (a, b) = ((a,b),[b])
  tenv <- introduceMonomorph (maybe id ((:) . (, recursionFuncTypeName)) name monotypes)
          <$> introduceTVars (map dupeB varNamesWithTypeVars)
        --  <$> maybe id setFuncTypeSig name 
          <$> askTypeEnv  
  (infStmts, subst) <- withTypeEnv (const tenv) . withReturnType (JSTVar returnTypeName) . listenTSubst $ inferStatement stmts
  let updatedFuncType = fromType . substituteType subst $ toType funcType
  subst' <- unifyExprs' updatedFuncType subst (JSTVar recursionFuncTypeName)
  returnInfer (LitFunc name argNames varNames infStmts) updatedFuncType subst'

unifyExprs' ::  JSType -> JSTSubst -> JSType -> Infer JSTSubst
unifyExprs' elemType lastSubst curType = runEither $ traceInfer "Unified: " $ unify lastSubst (traceInfer "unify lhs: " $ toType elemType) (traceInfer "unify rhs: " $ toType curType)

inferArray :: [Expr a] -> Infer (Expr JSType)
inferArray exprs = do
  elemTVarName <- fresh
  let elemType = JSTVar elemTVarName
  (infExprs, subst) <- accumInfer inferExpr exprs
  finalSubst <- foldM (unifyExprs' elemType) subst $ map exprData infExprs
  returnInfer (LitArray infExprs) (JSArray elemType) finalSubst


inferStatement :: Statement (Expr a) -> Infer (Statement (Expr JSType))
inferStatement Empty = return Empty
inferStatement (Expression expr) = inferExpr expr >>= \infExpr -> return (Expression infExpr)
inferStatement (Block stmts) = do
  (infStmts, subst) <- accumInfer inferStatement stmts
  tellTSubst subst
  return $ Block infStmts
inferStatement (IfThenElse expr stThen stElse) = do
  let infSt sub = listenTSubst . withTypeEnv (substituteTE sub) . inferStatement
  (expr', s0) <- listenTSubst . inferExpr $ expr
  (stThen', s1) <- infSt s0 stThen
  (stElse', s2) <- infSt s1 stElse
  let finalSubst = s2 `compose` s1 `compose` s0
  tellTSubst finalSubst
  return $ IfThenElse expr' stThen' stElse'
inferStatement (While expr st) = do
  let infSt sub = listenTSubst . withTypeEnv (substituteTE sub) . inferStatement
  (expr', s0) <- listenTSubst . inferExpr $ expr
  (st', s1) <- infSt s0 st
  let finalSubst = s1 `compose` s0
  tellTSubst finalSubst
  return $ While expr' st'
inferStatement (Return Nothing) = do
  (returnType, sub) <- listenTSubst askReturnType
  case returnType of
    Nothing -> typeFail $ GenericTypeError "Return encountered outside a function"
    Just t -> do
      s0 <- runEither $ unify sub (toType t) (toType JSUndefined)
      tellTSubst $ s0 `compose` sub
      return (Return Nothing)
inferStatement (Return (Just expr)) = do
  (returnType, s0) <- listenTSubst askReturnType
  case returnType of
    Nothing -> typeFail $ GenericTypeError "Return encountered outside a function"
    Just t -> do
      (infExpr, s1) <- listenTSubst . withTypeEnv (substituteTE s0) . inferExpr $ expr
      s2 <- runEither $ unify s1 (toType t) (toType . exprData $ infExpr)
      tellTSubst $ s2 `compose` s1 `compose` s0
      return (Return $ Just infExpr)
-- TODO implement var decls, possibly by removing this statement type and doing a pre-pass for var hoisting, so that LitFunc also has a list of var names
--inferStatement (VarDecl name) = do
  

----------------
