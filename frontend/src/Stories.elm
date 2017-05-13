module Stories exposing (tableView, tilesView, viewStory, findById, viewAnswersForm)

import AnswersForm
import Api exposing (Story)
import Bootstrap
import Dict
import Drawer
import Exts.List exposing (firstMatch)
import Html exposing (Html, br, div, img, h2, h3, p, text, label, input)
import Html.Attributes exposing (id, class, for, src, style, type_, value)
import Html.Events exposing (onInput)
import Json.Decode as JD
import Markdown
import Regex
import RemoteData exposing (WebData)
import Rest exposing (handleRemoteData)
import Routing exposing (pageToUrl, Page(..))
import Table
import Types exposing (Model, Msg(..), StoriesMsg(..), StoryData)
import View.Words


tilesView : StoryData -> List (Html Msg)
tilesView sd =
    let
        stories_ =
            handleRemoteData (mkTiles << List.take 20) sd.stories

        mkTiles stories =
            div [ class "storytiles" ] (List.map storyTile stories)

        storyStyle s =
            style [ ( "background", "url(pix/" ++ s.img ++ ")" ), ( "background-size", "cover" ) ]

        storyTile s =
            Html.a [ class "storytile", storyStyle s, Html.Attributes.href (pageToUrl (StoryPage s.id)) ]
                [ h3 [] [ text s.title ] ]
    in
        [ stories_ ]


tableConfig : Table.Config Story Msg
tableConfig =
    let
        tag i s =
            s.tags
                |> List.drop (i - 1)
                |> List.head
                |> Maybe.withDefault ""

        -- This is needed to make the level column wide enough so the heading and arrow
        -- don't wrap
        levelColumn : Table.Column Story Msg
        levelColumn =
            Table.veryCustomColumn
                { name = "Level"
                , viewData = \s -> Table.HtmlDetails [ style [ ( "width", "6em" ) ] ] [ Html.text (toString s.level) ]
                , sorter = Table.increasingOrDecreasingBy .level
                }

        storyTitleColumn : Table.Column Story Msg
        storyTitleColumn =
            Table.veryCustomColumn
                { name = "title"
                , viewData = viewStoryLink
                , sorter = Table.increasingOrDecreasingBy .title
                }

        viewStoryLink : Story -> Table.HtmlDetails Msg
        viewStoryLink s =
            Table.HtmlDetails []
                [ Html.a [ Html.Attributes.href (pageToUrl (StoryPage s.id)) ] [ text s.title ]
                ]
    in
        Table.customConfig
            { toId = .id
            , toMsg = StoriesMsg << SetTableState
            , columns =
                [ storyTitleColumn
                , Table.stringColumn "Curriculum" .curriculum
                , Table.stringColumn "Tag2" (tag 1)
                , Table.stringColumn "Tag3" (tag 2)
                , levelColumn
                ]
            , customizations = Bootstrap.tableCustomizations
            }


tableView : StoryData -> List (Html Msg)
tableView sd =
    [ Html.map StoriesMsg <|
        div []
            [ div [ class "form-group" ]
                [ label [ for "storyfilter" ] [ text "Search" ]
                , input
                    [ type_ "text"
                    , value sd.storyFilter
                    , onInput StoryFilterInput
                    , id "storyfilter"
                    ]
                    []
                ]
            ]
    , div [ class "table-responsive" ]
        [ handleRemoteData (Table.view tableConfig sd.tableState << filterStories sd.storyFilter) sd.stories ]
    ]


filterStories : String -> List Story -> List Story
filterStories storyFilter stories =
    if String.length storyFilter < 3 then
        stories
    else
        let
            r =
                Regex.caseInsensitive (Regex.regex storyFilter)

            match story =
                Regex.contains r story.title || Regex.contains r story.content
        in
            List.filter match stories


findById : StoryData -> String -> Maybe Story
findById sd id_ =
    case sd.stories of
        RemoteData.Success stories ->
            firstMatch (\s -> s.id == id_) stories

        _ ->
            Nothing


viewStory : StoryData -> String -> Html Msg
viewStory sd id_ =
    case findById sd id_ of
        Just s ->
            div []
                [ h2 [] [ text s.title ]
                , div [ id "storypic", picStyle sd.currentPicWidth ]
                    [ img [ onLoadGetWidth, src ("pix/" ++ s.img) ] []
                    ]
                , Markdown.toHtml [ id "storycontent" ] (storyContent s)
                , div [ id "storyfooter" ]
                    [ p [] [ text (String.join ", " s.tags), br [] [], text ("Level: " ++ toString s.level) ]
                    ]
                , View.Words.view (RemoteData.withDefault Dict.empty sd.wordDict) (Maybe.withDefault [] (Maybe.map List.singleton sd.dictLookup))
                ]

        _ ->
            text "Story not found"


storyContent : Story -> String
storyContent s =
    let
        replace m =
            "*" ++ (String.dropRight 1 m.match) ++ "*" ++ (String.right 1 m.match)

        re w =
            Regex.regex ((Regex.escape w.word) ++ "[^a-zA-z\\-]")

        replaceWord w content =
            Regex.replace Regex.All (re w) replace content
    in
        List.foldl replaceWord s.content s.words


picStyle : Int -> Html.Attribute msg
picStyle width =
    if width > 0 && width < 300 then
        style [ ( "float", "right" ) ]
    else
        style []


onLoadGetWidth : Html.Attribute Msg
onLoadGetWidth =
    Html.Events.on "load" (JD.succeed (GetImgWidth "#storypic img"))


viewAnswersForm : StoryData -> Html Msg
viewAnswersForm sd =
    case sd.answersForm of
        Nothing ->
            div [] []

        Just f ->
            Html.map (StoriesMsg << AnswersFormMsg) <|
                div [ id "activities" ]
                    [ h2 [] [ text "Answers" ]
                    , AnswersForm.view f
                    , Drawer.drawer (.showDrawer f)
                    ]
