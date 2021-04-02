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

module Hyperion.Closure.CPure ( cPure ) where

import           Control.Distributed.Static       (Closure)
import           Data.Binary                      (Binary)
import           Hyperion.Closure.Static.Class    (Serializable, Static (..),
                                                   cPure')
import           Hyperion.Closure.Static.Typeable ()
import           Type.Reflection                  (Typeable)

-- | Same as cPure', but gets the serialization dictionary from a
-- Static instance (defined below)
cPure :: forall a . (Static (Binary a), Typeable a) => a -> Closure a
cPure = cPure' (closureDict @(Serializable a))
