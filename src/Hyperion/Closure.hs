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
import           Data.Typeable              (Typeable)
import           GHC.Natural                (Natural)
import           GHC.StaticPtr              (StaticPtr)
import           GHC.TypeNats               (KnownNat, SomeNat (..), natVal,
                                             someNatVal)
import           Unsafe.Coerce              (unsafeCoerce)

-- | Turn a 'StaticPtr' into a 'Closure'
closurePtr :: Typeable a => StaticPtr a -> Closure a
closurePtr = staticClosure . staticPtr

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
cPure :: forall a . Static (Serializable a) => a -> Closure a
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

-- | Useful alias
type Serializable a = (Binary a, Typeable a)

-- | Unfortunately, there's a whole typeclass hierarchy to
-- duplicate...
instance Static (Serializable ()) where
  closureDict = closurePtr (static Dict)

instance Static (Serializable Natural) where
  closureDict = closurePtr (static Dict)

instance Static (Serializable Int) where
  closureDict = closurePtr (static Dict)

instance Static (Serializable Char) where
  closureDict = closurePtr (static Dict)

instance
  (Static (Serializable a)) =>
  Static (Serializable [a]) where
  closureDict = static (\Dict -> Dict) `ptrAp` closureDict @(Serializable a)

instance
  (Static (Serializable a1), Static (Serializable a2)) =>
  Static (Serializable (a1,a2)) where
  closureDict =
    static (\Dict Dict -> Dict) `ptrAp`
    closureDict @(Serializable a1) `cAp`
    closureDict @(Serializable a2)

instance
  (Static (Serializable a1), Static (Serializable a2), Static (Serializable a3)) =>
  Static (Serializable (a1,a2,a3)) where
  closureDict =
    static (\Dict Dict Dict -> Dict) `ptrAp`
    closureDict @(Serializable a1) `cAp`
    closureDict @(Serializable a2) `cAp`
    closureDict @(Serializable a3)

instance
  (Static (Serializable a1), Static (Serializable a2), Static (Serializable a3), Static (Serializable a4)) =>
  Static (Serializable (a1,a2,a3,a4)) where
  closureDict =
    static (\Dict Dict Dict Dict -> Dict) `ptrAp`
    closureDict @(Serializable a1) `cAp`
    closureDict @(Serializable a2) `cAp`
    closureDict @(Serializable a3) `cAp`
    closureDict @(Serializable a4)

-- | This horrible magic gives us free 'Static (KnownNat j)'
-- instances.
instance KnownNat j => Static (KnownNat j) where
  closureDict =
    closurePtr (static toKnownNatDictUnsafe) `cAp`
    cPure (natVal @j Proxy)

toKnownNatDictUnsafe :: Natural -> Dict (KnownNat l)
toKnownNatDictUnsafe n = case someNatVal n of
  SomeNat (Proxy :: Proxy k) -> unsafeCoerce (Dict @(KnownNat k))
{-# NOINLINE toKnownNatDictUnsafe #-}


-- TODO: This doesn't work! Perhaps GHC's internal representation of
-- the typeclass dictionary for 'Static c' is not the same
-- as in Given.
--
-- -- | We provide an interface inspired by 'Data.Reflection' to supply
-- -- 'Static c' instances on the fly.
-- newtype WithSC c r = WithSC (Static c => r)

-- -- | Supply an appropriate Static Dict on the fly. These tricks are
-- -- copied from the 'Given' typeclass in 'Data.Reflection', explained
-- -- here:
-- -- https://stackoverflow.com/questions/17793466/black-magic-in-haskell-reflection
-- --
-- -- TODO: These are very scary looking -- and I haven't tested them yet
-- -- to see if they work!
-- withClosureDict:: forall (c :: Constraint) r. c => Closure (Dict c) -> (Static c => r) -> r
-- withClosureDict sDict k = unsafeCoerce (WithSC k :: WithSC c r) sDict
-- {-# NOINLINE withStaticPtrDict #-}

-- withStaticPtrDict :: forall (c :: Constraint) r. (Typeable c, c) => StaticPtr (Dict c) -> (Static c => r) -> r
-- withStaticPtrDict sDict = withClosureDict (closurePtr sDict)
