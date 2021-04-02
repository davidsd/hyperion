{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StaticPointers      #-}
{-# LANGUAGE TemplateHaskell     #-}

module Hyperion.Closure.Static.Ord where

import           Data.Aeson                    ()
import           Data.Map                      ()
import           Data.Set                      ()
import           Data.Vector                   ()
import           Hyperion.Closure.Static.Class (Static (..))
import           Hyperion.Closure.Static.TH    (mkAllInstances)

mkAllInstances 'closureDict ''Static ''Ord

