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
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StaticPointers             #-}
{-# LANGUAGE TypeApplications           #-}

module Main where

import           Control.Distributed.Process (Process)
import           Control.Monad               ((>=>))
import           Data.Binary                 (Binary)
import           Data.Proxy                  (Proxy (..))
import qualified Data.Set                    as Set
import           Data.Text                   (Text)
import           Data.Typeable               (Typeable)
import           GHC.Generics                (Generic)
import           GHC.TypeNats                (KnownNat, natVal)
import           Hyperion
import qualified Hyperion.Log                as Log
import           Hyperion.Util               (withDict)
import           Hyperion.Static.Reflection (withClosureDict)

-- | A polymorphic function with a Show constraint
sayHello :: Show a => a -> Process String
sayHello x = pure ("Hello " <> show x <> "!")

-- | We can define a polymorphic function that calls 'sayHello'
-- remotely. However, it has 'Static (...)' constraints that must be
-- satisfied by the caller. Note that 'Static (Binary String)' is
-- provided in 'Hyperion.Static', which is why it doesn't appear here.
sayHelloRemote :: (Static (Show a), Static (Binary a), Typeable a) => a -> Job String
sayHelloRemote a =
  remoteClosure $
  static (withDict sayHello :: Dict (Show b) -> b -> Process String) `ptrAp` closureDict `cAp` cPure a

-- | Here's an example of providing the 'Static' instances
data Bar = MkBar
  deriving (Eq, Ord, Show, Generic, Binary)

-- | The instances are trivial since GHC can supply the 'Show Bar'
-- constraint automatically. But because of the 'static' keyword, we
-- must still write them. This could in principle be automated with
-- TemplateHaskell, as in
-- https://hackage.haskell.org/package/static-closure-0.1.0.0/docs/Control-Static-Closure-TH.html
--
-- With these instances we can use 'sayHelloRemote' with Bar.
instance Static (Show Bar) where closureDict = cPtr (static Dict)
instance Static (Binary Bar) where closureDict = cPtr (static Dict)

-- | Optionally, using withClosureDict, we can also supply 'Static'
-- instances "on the fly".
data Foo = MkFoo
  deriving (Eq, Ord, Show, Generic, Binary)

sayHelloRemoteFoo :: Foo -> Job String
sayHelloRemoteFoo =
  withClosureDict @(Show Foo) (cPtr (static Dict)) $
  withClosureDict @(Binary Foo) (cPtr (static Dict)) $
  sayHelloRemote @Foo

-- | In the above example, we had to define a bunch of 'Static'
-- instances whenever we wanted to use a new type. However, sometimes
-- we can generate them automatically. An example is 'KnownNat
-- j'. There is a magical instance 'KnownNat j => Static (KnownNat j)'
-- in 'Hyperion.Closure'. This allows us to define other 'Statics'
-- that build off of it.

-- | An integer with a type level integer label (who knows what this
-- is useful for...)
newtype IntLabeled j = MkIntLabeled Int
  deriving (Eq, Ord, Show, Generic)
  deriving anyclass (Binary)
  deriving newtype (Num)

-- | We can take advantage of 'KnownNat j => Static
-- (KnownNat j)' to get a serializable dictionary.
instance Typeable (IntLabeled j) => Static (Binary (IntLabeled j)) where
  closureDict = cPtr (static Dict)

-- | An IntLabeled equal to its label
tautology :: forall j . KnownNat j => IntLabeled j
tautology = MkIntLabeled (fromIntegral (natVal @j Proxy))

-- | Multiply a number by its label
multLabel :: KnownNat j => IntLabeled j -> Process (IntLabeled j)
multLabel = pure . (tautology *)

-- | Remotely multiply a number by its label. Polymorphic in j!
remoteMultLabel :: KnownNat j => IntLabeled j -> Job (IntLabeled j)
remoteMultLabel k = remoteClosure $
  static (withDict multLabel :: Dict (KnownNat k) -> IntLabeled k -> Process (IntLabeled k)) `ptrAp`
  closureDict `cAp`
  cPure k

-- | Remotely multiply a number by the cube of its label. This is
-- pretty inefficient...
remoteMultLabelCubed :: KnownNat j => IntLabeled j -> Job (IntLabeled j)
remoteMultLabelCubed = remoteMultLabel >=> remoteMultLabel >=> remoteMultLabel

remoteNubOrd :: (Typeable a, Static (Ord a), Static (Binary a)) => [a] -> Job [a]
remoteNubOrd xs = remoteClosure $
  static nubOrd `ptrAp` closureDict `cAp` cPure xs
  where
    nubOrd :: Dict (Ord b) -> [b] -> Process [b]
    nubOrd Dict = pure . Set.toList . Set.fromList

main :: IO ()
main = runJobLocal pInfo $ do
  Log.info "helloBar" =<< sayHelloRemote MkBar
  Log.info "helloFoo" =<< sayHelloRemoteFoo MkFoo
  Log.info "helloData" =<< sayHelloRemote ([MkBar, MkBar], 1 :: Integer, 'c', Just ("cool, huh?" :: Text))
  Log.info "remoteMultLabelCubed 42" =<< remoteMultLabelCubed (MkIntLabeled @42 1)
  Log.info "remoteMultLabelCubed 2"  =<< remoteMultLabelCubed (MkIntLabeled @2 1)
  Log.info "remoteNubOrd" =<< remoteNubOrd @(Int,Integer) [(1,2),(3,4),(1,2),(3,3),(3,4)]
  where
    pInfo = ProgramInfo
      { programId         = ProgramId "abc"
      , programDatabase   = "/central/home/dssimmon/projects/petr/hyperion-projects/test/test.sqlite"
      , programLogDir     = "/central/home/dssimmon/projects/petr/hyperion-projects/test"
      , programDataDir    = "/central/home/dssimmon/projects/petr/hyperion-projects/test"
      , programSSHCommand = Nothing
      }
