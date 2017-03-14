{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Monad (join)
import           Data.Monoid ((<>))
import           Data.Proxy (Proxy (Proxy))
import           Data.Text (Text)
import           Elm (Spec (Spec), specsToDir, toElmTypeSource, toElmDecoderSource, toElmEncoderSource)
import           GHC.TypeLits (KnownSymbol)
import           Servant.Elm (ElmOptions (..), defElmImports, defElmOptions, generateElmForAPIWith, UrlPrefix (Static))
import           Servant.Foreign hiding (Static)

import           Api.Types

elmOpts :: ElmOptions
elmOpts =
    defElmOptions
        { urlPrefix = Static "http://localhost:8000/api" }

specs :: [Spec]
specs =
    [ Spec ["Api"]
        (
            [  "import Dict exposing (Dict)"
            ,  defElmImports
            ]
           <> typeSources
           <> generateElmForAPIWith elmOpts (Proxy :: Proxy Api)
           <> codecSources
        )
    ]
  where
    typeSources = map fst sources
    codecSources = join (map snd sources)
    sources =
        sourceFor (Proxy :: Proxy Story)
        <> sourceFor (Proxy :: Proxy DictEntry)
        <> sourceFor (Proxy :: Proxy School)
        <> sourceFor (Proxy :: Proxy Class)
        <> sourceFor (Proxy :: Proxy Login)
        <> sourceFor (Proxy :: Proxy UserType)
        <> sourceFor (Proxy :: Proxy AccessToken)
        <> sourceFor (Proxy :: Proxy LoginRequest)

    sourceFor t = [ (toElmTypeSource t, [toElmDecoderSource t, toElmEncoderSource t]) ]

-- Add Authorization header argument to APIs with AuthProtect in them
instance (KnownSymbol sym, HasForeignType lang ftype Text, HasForeign lang ftype sublayout)
    => HasForeign lang ftype (AuthProtect sym :> sublayout) where
    type Foreign ftype (AuthProtect sym :> sublayout) = Foreign ftype sublayout

    foreignFor lang ftype Proxy req = foreignFor lang ftype (Proxy :: Proxy sublayout) req'
      where
        req' = req { _reqHeaders = HeaderArg arg : _reqHeaders req }
        arg = Arg
            { _argName = PathSegment "Authorization"
            , _argType = typeFor lang (Proxy :: Proxy ftype) (Proxy :: Proxy Text)
            }

main :: IO ()
main = specsToDir specs "frontend/src"