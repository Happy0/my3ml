module Types exposing (..)

import AddStudentsForm
import AnswersForm
import Api exposing (Class, Story, Student, DictEntry)
import Dict exposing (Dict)
import Form
import Login
import RemoteData exposing (WebData)
import Routing exposing (Page(..))
import Table


type Msg
    = ChangePage Page
    | Navigate Page
    | LoginMsg (Login.Msg Api.Login)
    | StoriesMsg StoriesMsg
    | SchoolDataMsg SchoolDataMsg
    | NoOp


type SchoolDataMsg
    = ClassesResponse (WebData (List Class))
    | StudentsResponse (WebData (List Student))
    | SchoolDataTableState Table.State
    | TeacherAction TeacherAction
    | StudentFormMsg Form.Msg


type StoriesMsg
    = StoriesResponse (WebData (List Story))
    | DictResponse (WebData WordDict)
    | StoryFilterInput String
    | SetTableState Table.State
    | ToggleDrawer DrawerType
    | ClearAnswers
    | FormMsg Form.Msg


type DrawerType
    = Connect
    | Question
    | Summarise
    | Clarify


type alias Definition =
    ( String, List ( String, Int ) )


type alias WordDict =
    Dict String (List Definition)


type alias StoryData =
    { stories : WebData (List Story)
    , storyFilter : String
    , tableState : Table.State
    , showDrawer : Maybe DrawerType
    , answersForm : AnswersForm.Model
    , wordDict : WebData WordDict
    }


type TeacherAction
    = ViewStudents
    | ViewClasses
    | ViewAnswers
    | AddStudents
    | AddClass


type alias SchoolData =
    { classes : WebData (List Class)
    , students : WebData (List Student)
    , tableState : Table.State
    , action : TeacherAction
    , addStudentsForm : AddStudentsForm.Model
    }


type alias Model =
    { storyData : StoryData
    , page : Page
    , mode : AppMode
    }


type AppMode
    = Anon Login.Model
    | StudentMode User
    | EditorMode User
    | TeacherMode User SchoolData
    | AdminMode User


type AccessToken
    = AccessToken String


type User
    = User String AccessToken


type UserType
    = Student
    | Teacher
    | Editor
    | Admin


type ClarifyWord
    = ClarifyWord String
