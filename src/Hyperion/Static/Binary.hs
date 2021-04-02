{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StaticPointers      #-}
{-# LANGUAGE TemplateHaskell     #-}

module Hyperion.Static.Binary where

import           Data.Binary           (Binary)
import           Data.Binary.Instances ()
import           Hyperion.Static.Class (Static (..))
import           Hyperion.Static.TH    (mkAllInstances)

mkAllInstances 'closureDict ''Static ''Binary
