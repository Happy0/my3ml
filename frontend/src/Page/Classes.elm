module Page.Classes exposing (Model, Msg, init, update, view)

import AddClassForm
import Api
import Bootstrap
import Data.Session as Session exposing (Session, authorization)
import Dialog
import Html exposing (..)
import Html.Attributes exposing (..)
import Page.Errored exposing (PageLoadError, pageLoadError)
import Route
import Table
import Task exposing (Task)
import Util exposing ((=>), dialog, defaultHttpErrorMsg)
import Views.TeacherToolbar as TeacherToolbar


type alias Model =
    { tableState : Table.State
    , addClassForm : Maybe AddClassForm.Model
    }


type Msg
    = SetTableState Table.State
    | AddClassFormMsg AddClassForm.Msg
    | DismissAddClass
    | ShowAddClass


init : Session -> Task PageLoadError ( Model, Session )
init session =
    let
        handleLoadError e =
            pageLoadError e ("Unable to load classes. " ++ defaultHttpErrorMsg e ++ ".")

        createModel session =
            Model (Table.initialSort "Class Name") Nothing
                => session
    in
        Session.loadClasses session
            |> Task.mapError handleLoadError
            |> Task.map createModel


update : Session -> Msg -> Model -> ( ( Model, Cmd Msg ), Session )
update session msg model =
    case msg of
        ShowAddClass ->
            { model | addClassForm = Just AddClassForm.init }
                => Cmd.none
                => session

        DismissAddClass ->
            { model | addClassForm = Nothing }
                => Cmd.none
                => session

        SetTableState state ->
            { model | tableState = state }
                => Cmd.none
                => session

        AddClassFormMsg subMsg ->
            case Maybe.map (AddClassForm.update session subMsg) model.addClassForm of
                Nothing ->
                    ( ( model, Cmd.none ), session )

                Just ( ( subModel, subSubMsg ), Nothing ) ->
                    { model | addClassForm = Just subModel }
                        => Cmd.map AddClassFormMsg subSubMsg
                        => session

                Just ( _, Just newClass ) ->
                    let
                        cache =
                            session.cache

                        newClasses =
                            newClass :: cache.classes

                        newSession =
                            { session | cache = { cache | classes = newClasses } }
                    in
                        { model | addClassForm = Nothing }
                            => Cmd.none
                            => newSession


view : Session -> Model -> Html Msg
view session model =
    div [ class "container page" ]
        [ TeacherToolbar.view session subtools
        , viewTable session model
        , Dialog.view (Maybe.map addClassesDialog model.addClassForm)
        ]


viewTable : Session -> Model -> Html Msg
viewTable session model =
    Table.view classesTableConfig model.tableState (.classes session.cache)


classesTableConfig : Table.Config Api.Class Msg
classesTableConfig =
    Table.customConfig
        { toId = .id
        , toMsg = SetTableState
        , columns =
            [ nameColumn
            , Table.stringColumn "Description" (Maybe.withDefault "" << .description)
            , Table.intColumn "Number of Students" (List.length << .students)
            ]
        , customizations = Bootstrap.tableCustomizations
        }


nameColumn : Table.Column Api.Class Msg
nameColumn =
    Table.veryCustomColumn
        { name = "Class name"
        , viewData = viewClassLink
        , sorter = Table.increasingOrDecreasingBy .name
        }


viewClassLink : Api.Class -> Table.HtmlDetails Msg
viewClassLink class =
    Table.HtmlDetails []
        [ a [ Route.href (Route.Teacher (Route.Class class.id)) ]
            [ text class.name
            ]
        ]


subtools : List (Html Msg)
subtools =
    [ Bootstrap.btn ShowAddClass [ text "Add Class" ] ]


addClassesDialog : AddClassForm.Model -> Dialog.Config Msg
addClassesDialog form =
    dialog
        DismissAddClass
        (Just (h3 [] [ text "Add Class" ]))
        (div []
            [ p [] [ text "Enter the new class name and a description" ]
            , AddClassForm.view form
                |> Html.map AddClassFormMsg
            ]
        )
