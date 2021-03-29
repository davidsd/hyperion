{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StaticPointers             #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE UndecidableSuperClasses    #-}

module Hyperion.RemoteBindConstrained where

import           Control.Concurrent.MVar             (newEmptyMVar)
import           Control.Distributed.Process         (Process)
import           Control.Distributed.Process.Closure (SerializableDict (..),
                                                      staticDecode)
import           Control.Distributed.Static
import           Control.Monad.Base                  (MonadBase (..))
import           Control.Monad.IO.Class              (MonadIO, liftIO)
import           Control.Monad.Trans.Control         (MonadBaseControl (..),
                                                      StM, control)
import           Data.Binary                         (Binary, encode)
import           Data.Constraint                     (Dict (..))
import           Data.Proxy                          (Proxy (..))
import           Data.Typeable                       (Typeable)
import           GHC.Generics                        (Generic)
import           GHC.StaticPtr                       (StaticPtr)
import           GHC.TypeNats                        (KnownNat, natVal)
import           Hyperion                            (Cluster, HasWorkers,
                                                      SerializableClosureProcess (..),
                                                      remoteEval, remoteFn,
                                                      tryLogException,
                                                      withRemoteRun)

-- | In the way that hyperion currently works, the user is expected to
-- use 'static (remoteFn f)'. 'remoteFn' packages the function f
-- together with SerializableDict's for its input and output
-- types. These types thus need to be known at compile time in order
-- to use the 'static' keyword. However, this makes it impossible to
-- use 'remoteEval' with a polymorphic function.
--
-- Instead, we can split up the computation of the StaticPtr to the
-- function and StaticPtr's to the SerializableDict's. This means we
-- can write polymorphic code, but we must explicitly thread through a
-- 'StaticPtr (Dict (...))' where (...) contains the constraints that
-- are eventually needed for serialization. The user must eventually
-- supply this 'StaticPtr (Dict (...))' through the use of 'static
-- Dict'. This can be done wherever the concrete type becomes known at
-- compile time.
--
-- Although this is slightly annoying, a nice benefit is that our
-- polymorphic functions can also carry constraints, and these can be
-- dealt with in the same way. That is, using this method we can
-- implement remoteEval for a function of type 'c => a -> Process b',
-- where 'c :: Constraint'. For example, we can deal with functions
-- that have a variable type-level precision, or a vector length, or
-- whatever.

-- | Turn a constrained function into one that takes an explicit Dict
-- argument. Also provide standard error handling for hyperion.
wrapConstrained :: (c => a -> Process b) -> Dict c -> a -> Process (Either String b)
wrapConstrained f Dict x = tryLogException f x

-- | A version of bind (>>=) that takes a monadic action 'ma' and a
-- continuation 'dictFn' and applies 'dictFn' to the result of 'ma' in
-- a remote location. Note that 'dictFn' takes an extra 'Dict c'
-- argument, which allows it to be constrained. Furthermore, the user
-- must explicitly supply a 'StaticPtr (Dict (...))' with the
-- appropriate constraints.
remoteBindConstrained
  :: forall a b c m .
     ( Binary a, Typeable a
     , Binary b, Typeable b
     , Typeable c, c
     , HasWorkers m, MonadIO m
     , StM m (SerializableClosureProcess (Either String b)) ~ SerializableClosureProcess (Either String b)
     , StM m a ~ a
     )
  => StaticPtr (Dict (Binary a, Typeable a, Binary b, Typeable b, c))
  -> m a
  -> StaticPtr (Dict c -> a -> Process (Either String b))
  -> m b
remoteBindConstrained staticDict ma dictFn = do
  v <- liftIO newEmptyMVar
  scp <- control $ \runInProcess ->
    pure $ SerializableClosureProcess
        { runClosureProcess = do
            a <- runInProcess ma
            pure $ closure (f `staticCompose` staticDecode aDict) (encode a)
        , staticSDict       = bDict
        , closureVar        = v
        }
  withRemoteRun $ \remoteRun -> liftBase $ remoteRun scp
  where
    s = staticPtr staticDict
    aDict = staticPtr (static (\Dict -> SerializableDict)) `staticApply` s
    bDict = staticPtr (static (\Dict -> SerializableDict)) `staticApply` s
    cDict = staticPtr (static (\Dict -> Dict))             `staticApply` s
    f = staticPtr dictFn `staticApply` cDict

-- | A flipped version of remoteBindConstrained where 'ma' is pure.
remoteEvalConstrained
  :: forall a b c m .
     ( Binary a, Typeable a
     , Binary b, Typeable b
     , Typeable c, c
     , HasWorkers m, MonadIO m
     , StM m (SerializableClosureProcess (Either String b)) ~ SerializableClosureProcess (Either String b)
     , StM m a ~ a
     )
  => StaticPtr (Dict (Binary a, Typeable a, Binary b, Typeable b, c))
  -> StaticPtr (Dict c -> a -> Process (Either String b))
  -> a
  -> m b
remoteEvalConstrained staticDict dictFn a =
  remoteBindConstrained staticDict (pure a) dictFn

-- An example using the Show class

sayHello :: Show a => a -> Process String
sayHello = pure . show

sayHelloDictStatic :: Typeable a => StaticPtr (Dict (Show a) -> a -> Process (Either String String))
sayHelloDictStatic = static (wrapConstrained sayHello)

data Foo = MkFoo
  deriving (Eq, Ord, Show, Generic, Binary)

sayHelloFoo :: Foo -> Cluster String
sayHelloFoo = remoteEvalConstrained (static Dict) sayHelloDictStatic

-- | In this case, since the argument is known at compile time, we can
-- alternatively use the old method.
sayHelloFoo' :: Foo -> Cluster String
sayHelloFoo' = remoteEval (static (remoteFn sayHello))

-- An example with KnownNat

-- | An integer with a type level integer label (who knows that this
-- is useful for...)
newtype IntLabeled j = MkIntLabeled Int
  deriving (Eq, Ord, Show, Generic)
  deriving anyclass (Binary)
  deriving newtype (Num)

tautology :: forall j . KnownNat j => IntLabeled j
tautology = MkIntLabeled (fromIntegral (natVal @j Proxy))

-- | Multiply a number by its label
multLabel :: forall j . KnownNat j => IntLabeled j -> Process (IntLabeled j)
multLabel = pure . (* tautology)

-- | An algorithm that repeatedly evaluates mapVec remotely, using the
-- user-supplied staticDict. Note that everything is still polymorphic
-- at this stage.
--
-- Note also the funny structure of the Dict (...) --- it has repeated
-- and redundant constraints. This comes from the type signature for
-- remoteEvalConstrained. This seems like kind of an abstraction
-- leak. Can we do better using tricks from Data.Constraint?
myAlgorithm
  :: (Typeable j, KnownNat j)
  => StaticPtr (Dict ( Binary (IntLabeled j)
                     , Typeable (IntLabeled j)
                     , Binary (IntLabeled j)
                     , Typeable (IntLabeled j)
                     , KnownNat j))
  -> IntLabeled j
  -> Cluster (IntLabeled j)
myAlgorithm staticDict i = do
  i'   <- remoteEvalConstrained staticDict multLabelStatic i
  i''  <- remoteEvalConstrained staticDict multLabelStatic i'
  i''' <- remoteEvalConstrained staticDict multLabelStatic i''
  pure i'''
  where
    multLabelStatic = static (wrapConstrained multLabel)

-- | Finally, when we want to use myAlgorithm, we have to supply a
-- static Dict.
myAlgorithm2 :: IntLabeled 42 -> Cluster (IntLabeled 42)
myAlgorithm2 = myAlgorithm (static Dict)

-- | The distributed-closure package implements something like
--
--     class c => StaticConstraint c where
--       staticDict :: Static (Dict c)
--
-- This allows one to specify Static Dicts once and not pass them
-- around as arguments. However, we then have the burden of
-- implementing a billion instances for StaticConstraint. In
-- experiments, this seemed to be much much more annoying than writing
-- 'static Dict' and having the type system infer which kind of Dict
-- you want.
