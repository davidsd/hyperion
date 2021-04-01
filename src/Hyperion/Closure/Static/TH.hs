{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE StaticPointers  #-}
{-# LANGUAGE TemplateHaskell #-}

module Hyperion.Closure.Static.TH where

import           Control.Distributed.Static (Closure)
import           Data.Constraint         (Dict (Dict))
import           Data.Monoid             (Endo (Endo, appEndo))
import           Data.Typeable           (Typeable)
import           Hyperion.Closure.Static.Class (cAp, cPtr)
import           Language.Haskell.TH     (Body (NormalB), Clause (Clause),
                                          Dec (FunD, InstanceD),
                                          Exp (AppE, ConE, InfixE, LamE, SigE, StaticE, VarE),
                                          Info (ClassI), InstanceDec, Name,
                                          Pat (ConP), Q,
                                          Type (AppT, ConT, ForallT, InfixT, ParensT, SigT, UInfixT, VarT),
                                          reify)

-- | The code for this module is mostly copied from the static-closure package
-- https://hackage.haskell.org/package/static-closure-0.1.0.0/docs/Control-Static-Closure-TH.html

getAllInstances :: Name -> Q [InstanceDec]
getAllInstances className = do
  result <- reify className
  case result of
    ClassI _ instanceDecs -> pure instanceDecs
    _                     -> fail "getAllInstances: Not a class"

mkInstance :: Name -> Name -> InstanceDec -> InstanceDec
mkInstance getClosureDictName staticClassName instanceDec = case instanceDec of
  InstanceD maybeOverlap oldCxt oldType _ ->
    let
      dictTypeName = ''Dict
      dictType = ConT dictTypeName
      dictValueName = 'Dict
      dictValue = ConE dictValueName
      dictPat = ConP dictValueName []
      closureClassName = ''Closure
      closureClass = ConT closureClassName
      capName = 'cAp
      capValue = VarE capName
      getClosureDict = VarE getClosureDictName
      addClassF = AppT (ConT staticClassName)
      addTypeableF = AppT (ConT ''Typeable)
      fromStaticPtrName = 'cPtr
      fromStaticPtrExp = VarE fromStaticPtrName
      newType = addClassF oldType
      newStaticCxt = addClassF <$> oldCxt
      newTypeableCxt = (addTypeableF . VarT) <$> ((oldType:oldCxt) >>= findAllTypeVars)
      newCxt = newTypeableCxt ++ newStaticCxt
      mkTypeSig cxt = AppT closureClass (AppT dictType cxt)
      mkArgExp cxt = SigE getClosureDict (mkTypeSig cxt)
      addArg x cxt = InfixE (Just x) capValue (Just (mkArgExp cxt))
      funcPart = case (length oldCxt) of
        0 -> dictValue
        n -> LamE (replicate n dictPat) dictValue
      body = NormalB (foldl addArg (AppE fromStaticPtrExp (StaticE funcPart)) oldCxt)
      clause = Clause [] body []
      funClause = FunD getClosureDictName [clause]
    in
      InstanceD maybeOverlap newCxt newType [funClause]
  _ -> error "mkInstance: Not an instance"

mkAllInstances :: Name -> Name -> Name -> Q [InstanceDec]
mkAllInstances getClosureDictName staticClassName className = (fmap . fmap) (mkInstance getClosureDictName staticClassName) (getAllInstances className)

findAllTypeVars :: Type -> [Name]
findAllTypeVars x = appEndo (go x) [] where
  go = \case
    ForallT{}       -> error "Don't know how do deal with Foralls in types"
    AppT t1 t2      -> go t1 <> go t2
    SigT t _        -> go t
    VarT name       -> Endo (name:)
    InfixT t1 _ t2  -> go t1 <> go t2
    UInfixT t1 _ t2 -> go t1 <> go t2
    ParensT t       -> go t
    _               -> mempty
