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

module Hyperion.Closure.Static.KnownNat where

import           Control.Distributed.Static    (Closure)
import           Data.Constraint               (Dict (..))
import           Data.Proxy                    (Proxy (..))
import           GHC.Natural                   (Natural)
import           GHC.TypeNats                  (KnownNat, SomeNat (..), natVal,
                                                someNatVal)
import           Hyperion.Closure.Static.Class (Serializable, Static (..), cPtr,
                                                cPure', ptrAp)
import           Unsafe.Coerce                 (unsafeCoerce)

-- | This magic gives us free 'Static (KnownNat j)' instances.
instance KnownNat j => Static (KnownNat j) where
  closureDict = static toKnownNatDictUnsafe `ptrAp` cPure' naturalSerDict (natVal @j Proxy)

naturalSerDict :: Closure (Dict (Serializable Natural))
naturalSerDict = cPtr (static Dict)

toKnownNatDictUnsafe :: Natural -> Dict (KnownNat l)
toKnownNatDictUnsafe n = case someNatVal n of
  SomeNat (Proxy :: Proxy k) -> unsafeCoerce (Dict @(KnownNat k))
{-# NOINLINE toKnownNatDictUnsafe #-}
