module Views.SelectLevel exposing (view)

import Html exposing (Html, select, option, text)
import Html.Attributes exposing (..)
import Html.Events exposing (on)
import Json.Decode as Json


view : (Int -> msg) -> Int -> Html msg
view toMsg current =
    let
        mkOption l =
            option [ selected (current == l), value (toString l) ] [ text ("Level " ++ toString l) ]

        intMsg =
            Json.at [ "target", "value" ] Json.string
                |> Json.andThen toInt
                |> Json.map toMsg

        toInt s =
            case String.toInt s of
                Ok i ->
                    Json.succeed i

                Err e ->
                    Json.fail e
    in
        select [ class "form-control", (on "input" intMsg) ]
            (List.map mkOption (List.range 0 9))
