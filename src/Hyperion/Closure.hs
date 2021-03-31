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

module Hyperion.Closure where

import           Control.Distributed.Static (Closure, closure, closureApply,
                                             staticClosure, staticPtr)
import           Data.Binary                (Binary, decode, encode)
import           Data.ByteString.Lazy       (ByteString)
import           Data.Constraint            (Dict (..))
import           Data.Proxy                 (Proxy (..))
import           GHC.Natural                (Natural)
import           GHC.StaticPtr              (StaticPtr)
import           GHC.TypeNats               (KnownNat, SomeNat (..), natVal,
                                             someNatVal)
import           Type.Reflection            (SomeTypeRep (..), TypeRep,
                                             Typeable, someTypeRep,
                                             withTypeable)
import           Unsafe.Coerce              (unsafeCoerce)

-- | Turn a 'StaticPtr' into a 'Closure'
closurePtr :: Typeable a => StaticPtr a -> Closure a
closurePtr = staticClosure . staticPtr

-- | Useful alias
type Serializable a = (Binary a, Typeable a)

-- | 'Closure' for a pure value that can be serialized
cPure' :: Serializable a => Closure (Dict (Serializable a)) -> a -> Closure a
cPure' cDict a =
  decodeDictStatic `cAp`
  cDict `cAp`
  closure staticId (encode a)
  where
    decodeDictStatic :: Typeable b => Closure (Dict (Serializable b) -> ByteString -> b)
    decodeDictStatic = closurePtr (static (\Dict -> decode))
    staticId = staticPtr (static id)

-- | Same as cPure', but gets the serialization dictionary from a
-- Static instance (defined below)
cPure :: forall a . (Static (Binary a), Typeable a) => a -> Closure a
cPure = cPure' (closureDict @(Serializable a))

-- | Apply a 'Closure' to another 'Closure'. This is just useful shorthand.
cAp :: Closure (a -> b) -> Closure a -> Closure b
cAp = closureApply

-- | A useful shortcut for 'cAp' for the case where the function is a
-- 'StaticPtr'.
ptrAp :: (Typeable a, Typeable b) => StaticPtr (a -> b) -> Closure a -> Closure b
ptrAp f x = closurePtr f `cAp` x

-- | A constraint whose dictionary is known statically. This
-- construction is copied from
-- https://hackage.haskell.org/package/distributed-closure-0.4.2.0/docs/Control-Distributed-Closure.html
-- (which, despite its confusing name, is not a library we use here,
-- since it is not used by Cloud Haskell).
class c => Static c where
  closureDict :: Closure (Dict c)

instance ( Static c1, Static c2
         , Typeable c1, Typeable c2
         ) => Static (c1,c2) where
  closureDict = static (\Dict Dict -> Dict) `ptrAp` closureDict @c1 `cAp` closureDict @c2

instance ( Static c1, Static c2, Static c3
         , Typeable c1, Typeable c2, Typeable c3
         ) => Static (c1,c2,c3) where
  closureDict = static (\Dict Dict Dict -> Dict) `ptrAp`
                closureDict @c1 `cAp`
                closureDict @c2 `cAp`
                closureDict @c3

instance ( Static c1, Static c2, Static c3, Static c4
         , Typeable c1, Typeable c2, Typeable c3, Typeable c4
         ) => Static (c1,c2,c3,c4) where
  closureDict = static (\Dict Dict Dict Dict -> Dict) `ptrAp`
                closureDict @c1 `cAp`
                closureDict @c2 `cAp`
                closureDict @c3 `cAp`
                closureDict @c4

instance ( Static c1, Static c2, Static c3, Static c4, Static c5
         , Typeable c1, Typeable c2, Typeable c3, Typeable c4, Typeable c5
         ) => Static (c1,c2,c3,c4,c5) where
  closureDict = static (\Dict Dict Dict Dict Dict -> Dict) `ptrAp`
                closureDict @c1 `cAp`
                closureDict @c2 `cAp`
                closureDict @c3 `cAp`
                closureDict @c4 `cAp`
                closureDict @c5

instance ( Static c1, Static c2, Static c3, Static c4, Static c5, Static c6
         , Typeable c1, Typeable c2, Typeable c3, Typeable c4, Typeable c5, Typeable c6
         ) => Static (c1,c2,c3,c4,c5,c6) where
  closureDict = static (\Dict Dict Dict Dict Dict Dict -> Dict) `ptrAp`
                closureDict @c1 `cAp`
                closureDict @c2 `cAp`
                closureDict @c3 `cAp`
                closureDict @c4 `cAp`
                closureDict @c5 `cAp`
                closureDict @c6

-- | Unfortunately, there's a whole typeclass hierarchy to
-- duplicate...
instance Static (Binary ()) where
  closureDict = closurePtr (static Dict)

instance Static (Binary Natural) where
  closureDict = closurePtr (static Dict)

instance Static (Binary Int) where
  closureDict = closurePtr (static Dict)

instance Static (Binary Char) where
  closureDict = closurePtr (static Dict)

instance
  (Static (Binary a), Typeable a) =>
  Static (Binary [a]) where
  closureDict = static (\Dict -> Dict) `ptrAp` closureDict @(Binary a)

instance
  (Static (Binary a1), Static (Binary a2), Typeable a1, Typeable a2) =>
  Static (Binary (a1,a2)) where
  closureDict =
    static (\Dict Dict -> Dict) `ptrAp`
    closureDict @(Binary a1) `cAp`
    closureDict @(Binary a2)

instance
  (Static (Binary a1), Static (Binary a2), Static (Binary a3), Typeable a1, Typeable a2, Typeable a3) =>
  Static (Binary (a1,a2,a3)) where
  closureDict =
    static (\Dict Dict Dict -> Dict) `ptrAp`
    closureDict @(Binary a1) `cAp`
    closureDict @(Binary a2) `cAp`
    closureDict @(Binary a3)

instance
  (Static (Binary a1), Static (Binary a2), Static (Binary a3), Static (Binary a4), Typeable a1, Typeable a2, Typeable a3, Typeable a4) =>
  Static (Binary (a1,a2,a3,a4)) where
  closureDict =
    static (\Dict Dict Dict Dict -> Dict) `ptrAp`
    closureDict @(Binary a1) `cAp`
    closureDict @(Binary a2) `cAp`
    closureDict @(Binary a3) `cAp`
    closureDict @(Binary a4)

-- | This magic gives us free 'Static (KnownNat j)' instances.
instance KnownNat j => Static (KnownNat j) where
  closureDict = static toKnownNatDictUnsafe `ptrAp` cPure (natVal @j Proxy)

toKnownNatDictUnsafe :: Natural -> Dict (KnownNat l)
toKnownNatDictUnsafe n = case someNatVal n of
  SomeNat (Proxy :: Proxy k) -> unsafeCoerce (Dict @(KnownNat k))
{-# NOINLINE toKnownNatDictUnsafe #-}

-- | Similarly, we can define free 'Static (Typeable a)' instances.
instance (Typeable a, Typeable k) => Static (Typeable (a :: k)) where
  closureDict = static toTypeableDictUnsafe `ptrAp` cPure' someTypeRepSerDict (someTypeRep (Proxy @a))

someTypeRepSerDict :: Closure (Dict (Serializable SomeTypeRep))
someTypeRepSerDict = closurePtr (static Dict)

toTypeableDictUnsafe :: forall k (a :: k) . SomeTypeRep -> Dict (Typeable a)
toTypeableDictUnsafe (SomeTypeRep (tr :: TypeRep b)) =
  withTypeable tr $ unsafeCoerce (Dict @(Typeable b))
{-# NOINLINE toTypeableDictUnsafe #-}
