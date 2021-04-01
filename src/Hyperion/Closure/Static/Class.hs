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

module Hyperion.Closure.Static.Class where

import           Control.Distributed.Static (Closure, closure, closureApply,
                                             staticClosure, staticPtr)
import           Data.Binary                (Binary, decode, encode)
import           Data.ByteString.Lazy       (ByteString)
import           Data.Constraint            (Dict (..))
import           GHC.StaticPtr              (StaticPtr)
import           Type.Reflection            (Typeable)

-- | The type of things that can be serialized
type Serializable a = (Binary a, Typeable a)

-- | Turn a 'StaticPtr' into a 'Closure'
cPtr :: Typeable a => StaticPtr a -> Closure a
cPtr = staticClosure . staticPtr

-- | 'Closure' for a pure value that can be serialized
cPure' :: Serializable a => Closure (Dict (Serializable a)) -> a -> Closure a
cPure' cDict a =
  decodeDictStatic `cAp`
  cDict `cAp`
  closure staticId (encode a)
  where
    decodeDictStatic :: Typeable b => Closure (Dict (Serializable b) -> ByteString -> b)
    decodeDictStatic = cPtr (static (\Dict -> decode))
    staticId = staticPtr (static id)

-- | Apply a 'Closure' to another 'Closure'. This is just useful shorthand.
cAp :: Closure (a -> b) -> Closure a -> Closure b
cAp = closureApply

-- | A useful shortcut for 'cAp' for the case where the function is a
-- 'StaticPtr'.
ptrAp :: (Typeable a, Typeable b) => StaticPtr (a -> b) -> Closure a -> Closure b
ptrAp f x = cPtr f `cAp` x

-- | A constraint whose dictionary is known statically. This
-- construction is copied from
-- https://hackage.haskell.org/package/distributed-closure-0.4.2.0/docs/Control-Distributed-Closure.html
-- (which, despite its confusing name, is not a library we use here,
-- since it is not used by Cloud Haskell).
class c => Static c where
  closureDict :: Closure (Dict c)

-- | TODO: Generate all of these with Template Haskell

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

instance ( Static c1, Static c2, Static c3, Static c4, Static c5, Static c6, Static c7
         , Typeable c1, Typeable c2, Typeable c3, Typeable c4, Typeable c5, Typeable c6, Typeable c7
         ) => Static (c1,c2,c3,c4,c5,c6,c7) where
  closureDict = static (\Dict Dict Dict Dict Dict Dict Dict -> Dict) `ptrAp`
                closureDict @c1 `cAp`
                closureDict @c2 `cAp`
                closureDict @c3 `cAp`
                closureDict @c4 `cAp`
                closureDict @c5 `cAp`
                closureDict @c6 `cAp`
                closureDict @c7

instance ( Static c1, Static c2, Static c3, Static c4, Static c5, Static c6, Static c7, Static c8
         , Typeable c1, Typeable c2, Typeable c3, Typeable c4, Typeable c5, Typeable c6, Typeable c7, Typeable c8
         ) => Static (c1,c2,c3,c4,c5,c6,c7,c8) where
  closureDict = static (\Dict Dict Dict Dict Dict Dict Dict Dict -> Dict) `ptrAp`
                closureDict @c1 `cAp`
                closureDict @c2 `cAp`
                closureDict @c3 `cAp`
                closureDict @c4 `cAp`
                closureDict @c5 `cAp`
                closureDict @c6 `cAp`
                closureDict @c7 `cAp`
                closureDict @c8
