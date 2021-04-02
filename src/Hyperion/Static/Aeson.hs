{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE StaticPointers       #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE UndecidableInstances #-}

module Hyperion.Static.Aeson where

import           Data.Aeson            (FromJSON, FromJSONKey, ToJSON,
                                        ToJSONKey)
import           Data.Map              ()
import           Data.Set              ()
import           Data.Vector           ()
import           Hyperion.Static.Class (Static (..))
import           Hyperion.Static.TH    (mkAllInstances)

mkAllInstances 'closureDict ''Static ''FromJSON
mkAllInstances 'closureDict ''Static ''FromJSONKey
mkAllInstances 'closureDict ''Static ''ToJSON
mkAllInstances 'closureDict ''Static ''ToJSONKey

