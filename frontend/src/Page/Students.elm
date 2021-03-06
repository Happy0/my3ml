module Page.Students exposing (Model, Msg, init, update, view)

import AddStudentsForm
import Api
import Bootstrap
import Data.Session as Session exposing (Session, authorization)
import Dialog
import Dict exposing (Dict)
import Exts.Html.Bootstrap exposing (formGroup, row)
import Exts.List exposing (firstMatch)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Http
import Page.Errored exposing (PageLoadError, pageLoadError)
import Ports
import Regex
import Table
import Task exposing (Task)
import Tuple exposing (first, second)
import Util exposing ((=>), viewIf, dialog, defaultHttpErrorMsg)
import Views.ClassSelect as ClassSelect
import Views.NewAccounts as NewAccounts
import Views.StudentTable as StudentTable
import Views.TeacherToolbar as TeacherToolbar


type alias Model =
    { tableState : Table.State
    , selectedStudents : Dict String Api.Student
    , studentAccountsCreated : List ( Api.Student, ( String, String ) )
    , addStudentsForm : Maybe AddStudentsForm.Model
    , studentFilter : ( String, Maybe String )
    }


type Msg
    = ClearSelectedStudents
    | ClearNewAccounts
    | PrintWindow
    | ShowAddStudents
    | DismissAddStudents
    | StudentFilterInput String
    | SetClassFilter (Maybe String)
    | SetTableState Table.State
    | SelectStudent Api.Student Bool
    | AddStudentsFormMsg AddStudentsForm.Msg
    | AddStudentsToClass (Maybe String)
    | ClassMembersResponse (Result Http.Error Api.Class)


init : Session -> Task PageLoadError ( Model, Session )
init session =
    let
        handleLoadError e =
            pageLoadError e ("Unable to load student data. " ++ defaultHttpErrorMsg e ++ ".")

        createModel session =
            Model StudentTable.init Dict.empty [] Nothing ( "", Nothing )
                => session
    in
        Session.loadStudents session
            |> Task.andThen (\newSession -> Session.loadClasses newSession)
            |> Task.mapError handleLoadError
            |> Task.map createModel


update : Session -> Msg -> Model -> ( ( Model, Cmd Msg ), Session )
update session msg model =
    case msg of
        ClearSelectedStudents ->
            { model | selectedStudents = Dict.empty } => Cmd.none => session

        ClearNewAccounts ->
            { model | studentAccountsCreated = [] } => Cmd.none => session

        StudentFilterInput txt ->
            { model | studentFilter = ( txt, second model.studentFilter ) } => Cmd.none => session

        PrintWindow ->
            model => Ports.printWindow () => session

        SetClassFilter c ->
            { model | studentFilter = ( first model.studentFilter, c ) } => Cmd.none => session

        SelectStudent student checked ->
            let
                f =
                    if checked then
                        Dict.insert student.id student
                    else
                        Dict.remove student.id
            in
                { model | selectedStudents = f model.selectedStudents } => Cmd.none => session

        AddStudentsFormMsg subMsg ->
            case Maybe.map (AddStudentsForm.update session subMsg) model.addStudentsForm of
                Nothing ->
                    ( model, Cmd.none ) => session

                Just ( ( subModel, subSubMsg ), Nothing ) ->
                    { model | addStudentsForm = Just subModel } => Cmd.map AddStudentsFormMsg subSubMsg => session

                Just ( _, Just newAccounts ) ->
                    let
                        cache =
                            session.cache

                        accountsCreated =
                            newAccounts ++ model.studentAccountsCreated

                        newStudents =
                            List.map first newAccounts

                        newSession =
                            { session | cache = { cache | students = List.append newStudents cache.students } }
                    in
                        { model | addStudentsForm = Nothing, studentAccountsCreated = accountsCreated }
                            => Cmd.none
                            => newSession

        SetTableState state ->
            { model | tableState = state } => Cmd.none => session

        ShowAddStudents ->
            { model | addStudentsForm = Just AddStudentsForm.init } => Cmd.none => session

        DismissAddStudents ->
            { model | addStudentsForm = Nothing } => Cmd.none => session

        AddStudentsToClass classId ->
            case classId of
                Nothing ->
                    model => Cmd.none => session

                Just cid ->
                    let
                        studentsToAdd =
                            Dict.values model.selectedStudents
                                |> List.map (.id)
                    in
                        { model | selectedStudents = Dict.empty }
                            => (Api.postSchoolClassesByClassIdMembers (authorization session) cid Nothing studentsToAdd
                                    |> Http.send ClassMembersResponse
                               )
                            => session

        ClassMembersResponse (Ok updatedClass) ->
            let
                cache =
                    session.cache

                newClasses =
                    updatedClass
                        :: List.filter (\c -> c.id /= updatedClass.id) cache.classes

                newSession =
                    { session | cache = { cache | classes = newClasses } }
            in
                model => Cmd.none => newSession

        ClassMembersResponse (Err _) ->
            model => Cmd.none => session


view : Session -> Model -> Html Msg
view session model =
    div [ class "container page" ]
        [ TeacherToolbar.view session (subtools session)
        , row [ NewAccounts.view PrintWindow ClearNewAccounts model.studentAccountsCreated ]
        , viewStudentsFilter session.cache model
        , viewTable session.cache model
        , Dialog.view (Maybe.map addStudentsDialog model.addStudentsForm)
        ]


subtools : Session -> List (Html Msg)
subtools session =
    if Session.isSchoolAdmin session then
        [ Bootstrap.btn ShowAddStudents [ text "Add Students" ]
        ]
    else
        []


viewTable : Session.Cache -> Model -> Html Msg
viewTable cache model =
    let
        elements =
            filterStudents cache model

        tableConfig =
            StudentTable.config SetTableState SelectStudent

        isChecked s =
            Dict.member s.id model.selectedStudents
    in
        div [ class "row hidden-print" ]
            [ StudentTable.view tableConfig model.tableState elements isChecked
            ]


filterStudents : Session.Cache -> Model -> List Api.Student
filterStudents cache model =
    case model.studentFilter of
        ( _, Just classId ) ->
            findStudentsInClass cache classId
                |> Maybe.map (filterByStudentIds cache.students)
                |> Maybe.withDefault []

        ( nameFilter, Nothing ) ->
            if String.length nameFilter < 3 then
                cache.students
            else
                filterStudentsByName nameFilter cache.students


findStudentsInClass : Session.Cache -> String -> Maybe (List String)
findStudentsInClass cache classId =
    firstMatch (\c -> c.id == classId) cache.classes
        |> Maybe.map .students


filterByStudentIds : List Api.Student -> List String -> List Api.Student
filterByStudentIds students ids =
    List.filter (\s -> List.member s.id ids) students


filterStudentsByName : String -> List Api.Student -> List Api.Student
filterStudentsByName nameFilter students =
    Regex.caseInsensitive (Regex.regex nameFilter)
        |> \r -> List.filter (\s -> Regex.contains r s.name) students


viewStudentsFilter : Session.Cache -> Model -> Html Msg
viewStudentsFilter cache model =
    let
        onSelect msg classId =
            msg <|
                if classId == "" then
                    Nothing
                else
                    (Just classId)

        inputGroupBtn msg txt =
            span [ class "input-group-btn" ]
                [ button [ class "btn btn-default", onClick msg, type_ "button" ] [ text txt ]
                ]
    in
        div [ class "row hidden-print" ]
            [ div [ class "form-inline" ]
                [ formGroup
                    [ input
                        [ class "form-control"
                        , type_ "text"
                        , value (first model.studentFilter)
                        , onInput StudentFilterInput
                        , placeholder "Name search"
                        , id "studentNameFilter"
                        ]
                        []
                    , ClassSelect.view cache.classes (second model.studentFilter) "Filter by class" (onSelect SetClassFilter)
                    ]
                , if Dict.isEmpty model.selectedStudents then
                    div [] []
                  else
                    div [ class "input-group" ]
                        [ span [ class "input-group-btn" ]
                            [ button [ class "btn btn-default", onClick ClearSelectedStudents, type_ "button" ] [ text "Clear selection" ]
                            ]
                        , ClassSelect.view cache.classes Nothing "Add selected students to class" (onSelect AddStudentsToClass)
                        ]
                ]
            ]


addStudentsDialog : AddStudentsForm.Model -> Dialog.Config Msg
addStudentsDialog form =
    dialog
        DismissAddStudents
        (Just (h3 [] [ text "Add Students" ]))
        (div []
            [ p [] [ text "Enter the names of the students you want to add accounts for, separated by commas or on separate lines" ]
            , AddStudentsForm.view form
                |> Html.map AddStudentsFormMsg
            ]
        )
