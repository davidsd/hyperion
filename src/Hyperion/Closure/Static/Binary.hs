{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StaticPointers      #-}
{-# LANGUAGE TemplateHaskell     #-}

module Hyperion.Closure.Static.Binary where

import           Data.Binary                   (Binary)
import           Data.Binary.Instances         ()
import           Hyperion.Closure.Static.Class (Static (..))
import           Hyperion.Closure.Static.TH    (mkAllInstances)

mkAllInstances 'closureDict ''Static ''Binary
