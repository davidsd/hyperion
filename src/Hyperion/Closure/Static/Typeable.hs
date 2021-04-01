{-# OPTIONS_GHC -fno-warn-orphans #-}
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

module Hyperion.Closure.Static.Typeable where

import           Control.Distributed.Static    (Closure)
import           Data.Constraint               (Dict (..))
import           Data.Proxy                    (Proxy (..))
import           Hyperion.Closure.Static.Class (Serializable, Static (..), cPtr,
                                                cPure', ptrAp)
import           Type.Reflection               (SomeTypeRep (..), TypeRep,
                                                Typeable, someTypeRep,
                                                withTypeable)
import           Unsafe.Coerce                 (unsafeCoerce)

-- | Similarly, we can define free 'Static (Typeable a)' instances.
instance (Typeable a, Typeable k) => Static (Typeable (a :: k)) where
  closureDict = static toTypeableDictUnsafe `ptrAp` cPure' someTypeRepSerDict (someTypeRep (Proxy @a))

someTypeRepSerDict :: Closure (Dict (Serializable SomeTypeRep))
someTypeRepSerDict = cPtr (static Dict)

toTypeableDictUnsafe :: forall k (a :: k) . SomeTypeRep -> Dict (Typeable a)
toTypeableDictUnsafe (SomeTypeRep (tr :: TypeRep b)) =
  withTypeable tr $ unsafeCoerce (Dict @(Typeable b))
{-# NOINLINE toTypeableDictUnsafe #-}
