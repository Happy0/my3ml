{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RecordWildCards #-}
module HasqlDB where

import           Control.Exception.Safe
import           Control.Monad (when, replicateM)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Contravariant.Extras.Contrazip
import qualified Data.Aeson as JSON
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import           Data.Functor.Contravariant
import           Data.Function (on)
import           Data.Int (Int64)
import           Data.List (foldl', groupBy)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe)
import           Data.Monoid
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import           Hasql.Query (Query)
import           Hasql.Pool (Pool, use, acquire)
import qualified Hasql.Query as Q
import qualified Hasql.Encoders as E
import qualified Hasql.Decoders as D
import qualified Hasql.Session as S
import           Prelude hiding (id, words)
import           Text.Read (readMaybe)

import Api.Types
import DB


mkDB :: String -> IO HasqlDB
mkDB connStr = H <$> acquire (10, 120, BC.pack connStr)

newtype HasqlDB = H Pool

instance DB HasqlDB where
    registerNewAccount Registration {..} db = runSession db $ do
        begin
        schoolId_ <- S.query (schoolName, Nothing) insertSchool
        subId <- S.query (email, password, schoolAdmin) insertAccount
        S.query (subId, teacherName, schoolId_) insertTeacher
        commit

    getAccountByUsername = runQuery selectAccountByUsername

    getStories = runQuery selectAllStories ()

    getStory = runQuery selectStoryById

    createStory story db = runSession db $
        S.query story insertStory

    updateStory story db = runSession db $ do
        S.query story updateStory_
        ms <- S.query ((id :: Story -> StoryId) story) selectStoryById
        updatedFromMaybe ms

    getSchools = runQuery selectAllSchools ()

    getSchool = runQuery selectSchoolById

    getTrails = runQuery selectTrailsBySchoolId

    createTrail = runQuery insertTrail

    deleteTrail trailId_ db = do
        nRows <- runQuery deleteTrailById trailId_ db
        when (nRows == 0) $ liftIO $ throwString "Trail not found to delete"

    getClasses = runQuery selectClassesBySchool

    addClassMembers schoolId_ classId_ studentIds db = runSession db $ do
        S.query (schoolId_, classId_, studentIds) insertClassMembers
        mc <- S.query classId_ selectClassById
        updatedFromMaybe mc

    removeClassMembers schoolId_ classId_ studentIds db = runSession db $ do
        S.query (schoolId_, classId_, studentIds) deleteClassMembers
        mc <- S.query classId_ selectClassById
        updatedFromMaybe mc

    getClass = runQuery selectClassById

    createClass = runQuery insertClass

    deleteClass classId_ schoolId_ db = do
        nRows <- runQuery deleteClassById (classId_, schoolId_) db
        when (nRows == 0) $ liftIO $ throwString "Class not found to delete"

    getStudents = runQuery selectStudentsBySchool

    getStudent schoolId_ studentId_ = runQuery selectStudentById (studentId_, schoolId_)

    getStudentBySubjectId = runQuery selectStudentBySubjectId

    createStudent (nm, lvl, schoolId_) (username, password) db = runSession db $ do
        begin
        subId <- S.query (username, password, student) insertAccount
        let subIdText = UUID.toText subId
            s = Student subIdText nm Nothing lvl schoolId_ False Nothing
        S.query (s, subId) insertStudent
        commit
        S.query subIdText selectStudentBySubjectId

    updateStudent student_ schoolId_ db = runSession db $ do
        S.query (student_, schoolId_) updateStudent_
        S.query ((id :: Student -> SubjectId) student_) selectStudentBySubjectId


    deleteStudent subjectId_ schoolId_ db = runSession db $ do
        begin
        S.query (subjectId_, schoolId_) $
            Q.statement "UPDATE student SET deleted=now() WHERE id=$1 :: uuid AND school_id = $2 :: uuid AND deleted is null"
              (contramap fst evText <>  contramap snd evText) D.unit True
        S.query subjectId_ $
            Q.statement "UPDATE login SET locked=true WHERE id=$1 :: uuid"
              evText D.unit True
        commit
        S.query subjectId_ selectStudentBySubjectId

    undeleteStudent subjectId_ schoolId_ db = runSession db $ do
        begin
        S.query (subjectId_, schoolId_) $
            Q.statement "UPDATE student SET deleted=null WHERE id=$1 :: uuid AND school_id = $2 :: uuid"
              (contramap fst evText <>  contramap snd evText) D.unit True
        S.query subjectId_ $
            Q.statement "UPDATE login SET locked=false WHERE id=$1 :: uuid"
              evText D.unit True
        commit

    setStudentPassword schoolId_ studentId_ password_ =
        runQuery updateStudentPassword (schoolId_, studentId_, password_)

    setStudentUsername schoolId_ studentId_ username_ =
        runQuery updateStudentUsername (schoolId_, studentId_, username_)

    getTeacherBySubjectId = runQuery selectTeacherBySubjectId

    getDictionary db = do
        elts <- groupBy ((==) `on` fst) <$> runQuery selectDictionary () db
        return $ Map.fromList (map dictWord elts)

    lookupWord = runQuery selectWord

    getAnswers schoolId_ studentId_ storyId_ db = case (studentId_, storyId_) of
        (Just sid, _) -> runQuery selectAnswersByStudent (sid, schoolId_) db
        (_, Just sid) -> runQuery selectAnswersByStory (schoolId_, sid) db
        _ -> runQuery selectAnswersBySchool schoolId_ db

    createAnswer = runQuery insertAnswer

    generateWords db =
      let
        query = Q.statement "SELECT word FROM dict WHERE sensitive = FALSE ORDER BY random() LIMIT 10" E.unit (D.rowsList (D.value D.text)) True
      in
        runSession db (S.query () query)

    generateUsername prefix db = do
        let query = Q.statement "SELECT replace(username, $1, '') FROM login WHERE username LIKE $1 || '%'" evText (D.rowsList (D.value D.text)) True
        suffixes <- map (fromMaybe (0 :: Int) . readMaybe . T.unpack) <$> runSession db (S.query prefix query)
        let newName = case suffixes of
              [] -> prefix
              _ -> T.pack $ T.unpack prefix ++ show (maximum suffixes + 1)
        return newName

    getLeaderBoard = runQuery selectLeaderboardBySchoolId

    updateAccountSettings = runQuery updateAccountSettings_

updatedFromMaybe :: MonadIO m => Maybe a -> m a
updatedFromMaybe (Just a) = return a
updatedFromMaybe Nothing = liftIO $ throwString "Couldn't find entity after updating. Shouldn't happen."



dictWord :: [(Text, b)] -> (Text, [b])
dictWord ((w, meaning):ws) = (w, meaning : map snd ws)
dictWord [] = ("", []) -- shouldn't happen


runQuery :: MonadIO m => Query p a -> p -> HasqlDB -> m a
runQuery q p db = runSession db (S.query p q)

runSession :: MonadIO m => HasqlDB -> S.Session a -> m a
runSession (H pool) s = liftIO $ do
    result <- use pool s
    case result of
        Left e -> liftIO $ throwString (show e)
        Right r -> return r

begin :: S.Session ()
begin = S.sql "begin"

commit :: S.Session ()
commit = S.sql "commit"

dvText :: D.Row Text
dvText = D.value D.text

evText :: E.Params Text
evText = E.value E.text

eTextPair :: E.Params (Text, Text)
eTextPair = contramap fst evText <> contramap snd evText

evUserType :: E.Params UserType
evUserType = E.value (contramap userType E.text)

dvUUID :: D.Row Text
dvUUID = UUID.toText <$> D.value D.uuid

dArray :: D.Value a -> D.Row [a]
dArray v = D.value (D.array (D.arrayDimension replicateM (D.arrayValue v)))

eArray :: Foldable t => E.Value b -> E.Params (t b)
eArray v = E.value (E.array (E.arrayDimension foldl' (E.arrayValue v)))


dictEntryValue :: D.Value DictEntry
dictEntryValue = D.composite (DictEntry <$> D.compositeValue D.text <*> (fromIntegral <$> D.compositeValue D.int2))

dictEntryTupleValue :: D.Value (Text, Int)
dictEntryTupleValue = D.composite ((,) <$> D.compositeValue D.text <*> (fromIntegral <$> D.compositeValue D.int2))


userTypeValue :: D.Row UserType
userTypeValue = -- D.composite (uType <$> D.compositeValue D.text)
    uType <$> dvText
  where
    uType t = case T.unpack t of
        "Teacher" -> teacher
        "SchoolAdmin" -> schoolAdmin
        "Admin" -> admin
        "Editor" -> editor
        _ -> student

-- User accounts

selectAccountByUsername :: Query Text (Maybe Account)
selectAccountByUsername = Q.statement sql evText (D.maybeRow decode) True
  where
    sql = "SELECT login.id, username, password, user_type :: text, level, active, settings \
          \ FROM login \
          \ LEFT JOIN student \
          \ ON login.id = student.id \
          \ WHERE username = lower($1) AND locked = false"

    decode = Account
        <$> dvUUID
        <*> dvText
        <*> dvText
        <*> userTypeValue
        <*> (maybe 10 fromIntegral <$> D.nullableValue D.int2)
        <*> D.value D.bool
        <*> D.nullableValue D.jsonb

insertAccount :: Query (Text, Text, UserType) UUID.UUID
insertAccount = Q.statement sql encode (D.singleRow (D.value D.uuid))True
  where
    sql = "INSERT INTO login (username, password, user_type) VALUES (lower($1), $2, $3 :: user_type) RETURNING id"
    encode = contrazip3 evText evText evUserType

updateStudentPassword :: Query (SchoolId, SubjectId, Text) ()
updateStudentPassword = Q.statement sql encode D.unit True
  where
    sql = "UPDATE login SET password = $3 \
          \ WHERE id = (SELECT id from student WHERE id = $2 :: uuid and school_id = $1 :: uuid)"
    encode = contramap (\(sid, _, _) -> sid) evText
        <> contramap (\(_, sid, _) -> sid) evText
        <> contramap (\(_, _, pwd) -> pwd) evText

updateStudentUsername :: Query (SchoolId, SubjectId, Text) ()
updateStudentUsername = Q.statement sql encode D.unit True
  where
    sql = "UPDATE login SET username = $3 \
          \ WHERE id = (SELECT id from student WHERE id = $2 :: uuid and school_id = $1 :: uuid)"
    encode = contramap (\(sid, _, _) -> sid) evText
        <> contramap (\(_, sid, _) -> sid) evText
        <> contramap (\(_, _, nm) -> nm) evText

-- Stories

selectStorySql :: ByteString
selectStorySql = "SELECT id, title, img_url, level, qualification, curriculum, tags, content, words, clarify_word FROM story"

selectAllStories :: Query () [Story]
selectAllStories =
    Q.statement selectStorySql mempty (D.rowsList storyRow) True

selectStoryById :: Query StoryId (Maybe Story)
selectStoryById =
    Q.statement (selectStorySql <> " WHERE id = $1") evStoryId (D.maybeRow storyRow) True
  where
    evStoryId =
      contramap fromIntegral (E.value E.int4)

storyRow :: D.Row Story
storyRow = Story
    <$> (fromIntegral <$> D.value D.int4)
    <*> dvText
    <*> dvText
    <*> (fromIntegral <$> D.value D.int2)
    <*> dvText
    <*> D.nullableValue D.text
    <*> dArray D.text
    <*> dvText
    <*> dArray dictEntryValue
    <*> dvText
--    <*> D.value D.timestamptz

insertStory :: Query Story StoryId
insertStory = Q.statement sql storyEncoder (D.singleRow $ fromIntegral <$> D.value D.int4) True
  where
    sql = "INSERT INTO story (title, img_url, level, qualification, curriculum, tags, content, words, clarify_word) \
                 \VALUES ($2, $3, $4, $5, $6, $7, $8, (array(select word::dict_entry from unnest ($9, $10) as word)), $11) \
                 \RETURNING id"

updateStory_ :: Query Story ()
updateStory_ = Q.statement sql storyEncoder D.unit True
  where
    sql = "UPDATE story SET title=$2, img_url=$3, level=$4, qualification=$5, curriculum=$6, tags=$7, content=$8, words=(array(select word::dict_entry from unnest ($9, $10) as word)), clarify_word=$11 WHERE id=$1"

storyEncoder :: E.Params Story
storyEncoder = contramap (fromIntegral . (id :: Story -> StoryId)) (E.value E.int4)
    <> contramap title evText
    <> contramap img evText
    <> contramap (fromIntegral . storyLevel) (E.value E.int4)
    <> contramap qualification evText
    <> contramap curriculum (E.nullableValue E.text)
    <> contramap tags (eArray E.text)
    <> contramap content evText
    <> contramap (map word . words) (eArray E.text)
    <> contramap (map (fromIntegral . index) . words) (eArray E.int2)
    <> contramap clarifyWord evText
    -- <> contramap date (E.value E.timestamptz)
  where
    storyLevel = level :: Story -> Int

-- School

insertSchool :: Query (Text, Maybe Text) UUID.UUID
insertSchool = Q.statement sql encode (D.singleRow (D.value D.uuid)) False
  where
    sql = "INSERT INTO school (name, description) values ($1, $2) RETURNING id"
    encode = contramap fst evText
        <> contramap snd (E.nullableValue E.text)

-- Teachers

selectTeacherSql :: ByteString
selectTeacherSql = "SELECT id, name, bio, school_id FROM teacher"

selectTeacherBySubjectId :: Query SubjectId Teacher
selectTeacherBySubjectId = Q.statement sql evText (D.singleRow teacherRow) True
  where
    sql = selectTeacherSql <> " WHERE id = $1 :: uuid"

teacherRow :: D.Row Teacher
teacherRow = Teacher
    <$> dvUUID
    <*> dvText
    <*> D.nullableValue D.text
    <*> dvUUID

insertTeacher :: Query (UUID.UUID, Text, UUID.UUID) ()
insertTeacher = Q.statement sql encode D.unit False
  where
    sql = "INSERT INTO teacher (id, name, school_id) VALUES ($1, $2, $3)"
    encode = contrazip3 (E.value E.uuid) evText (E.value E.uuid)

-- Students

selectStudentSql :: ByteString
selectStudentSql = "SELECT id, name, description, level, school_id, hidden, deleted FROM student"

selectStudentsBySchool :: Query SchoolId [Student]
selectStudentsBySchool = Q.statement sql evText (D.rowsList studentRow) True
  where
    sql = selectStudentSql <> " WHERE school_id = $1 :: uuid"

selectStudentById :: Query (SubjectId, SchoolId) (Maybe Student)
selectStudentById = Q.statement sql eTextPair (D.maybeRow studentRow) True
  where
    sql = selectStudentSql <> " WHERE id = $1 :: uuid AND school_id = $2 :: uuid"

selectStudentBySubjectId :: Query SubjectId Student
selectStudentBySubjectId = Q.statement sql evText (D.singleRow studentRow) True
  where
    sql = selectStudentSql <> " WHERE id = $1 :: uuid"

studentRow :: D.Row Student
studentRow = Student
    <$> dvUUID
    <*> dvText
    <*> D.nullableValue D.text
    <*> (fromIntegral <$> D.value D.int2)
    <*> dvUUID
    <*> D.value D.bool
    <*> D.nullableValue D.timestamptz

insertStudent :: Query (Student, UUID.UUID) ()
insertStudent = Q.statement sql encode D.unit True
  where
    sql = "INSERT INTO student (id, name, description, level, school_id) VALUES ($1, $2, $3, $4, $5 :: uuid)"
    encode = contramap snd (E.value E.uuid)
        <> contramap ((name :: Student -> Text) . fst) evText
        <> contramap ((description :: Student -> Maybe Text) . fst) (E.nullableValue E.text)
        <> contramap ((fromIntegral . (level :: Student -> Int)) . fst) (E.value E.int4)
        <> contramap ((schoolId :: Student -> SchoolId) . fst) evText

updateStudent_ :: Query (Student, SchoolId) ()
updateStudent_ = Q.statement sql encode D.unit True
  where
    sql = "UPDATE student SET name=$1, description=$2, level=$3, hidden=$4 \
          \ WHERE id=$5 :: uuid AND school_id=$6 :: uuid"
    encode = contramap ((name :: Student -> Text) . fst) evText
        <> contramap ((description :: Student -> Maybe Text) . fst) (E.nullableValue E.text)
        <> contramap ((fromIntegral . (level :: Student -> Int)) . fst) (E.value E.int4)
        <> contramap ((hidden :: Student -> Bool) . fst) (E.value E.bool)
        <> contramap ((id :: Student -> SubjectId) . fst) evText
        <> contramap snd evText

-- Schools

selectSchoolSql :: ByteString
selectSchoolSql = "SELECT id, name, description FROM school"

selectAllSchools :: Query () [School]
selectAllSchools =
    Q.statement selectSchoolSql mempty (D.rowsList schoolRow) True

selectSchoolById :: Query SchoolId (Maybe School)
selectSchoolById =
    Q.statement (selectSchoolSql <> " WHERE id = $1 :: uuid") evText (D.maybeRow schoolRow) True

schoolRow :: D.Row School
schoolRow = School
    <$> dvUUID
    <*> dvText
    <*> D.nullableValue D.text


-- Classes

selectClassSql :: ByteString
selectClassSql = "SELECT id, name, description, school_id, created_by, array(SELECT student_id :: text FROM student_class WHERE class_id = class.id) AS students FROM class"

selectClassesBySchool :: Query SchoolId [Class]
selectClassesBySchool = Q.statement sql evText (D.rowsList classRow) True
  where
    sql = selectClassSql <> " WHERE school_id = $1 :: uuid"

selectClassById :: Query ClassId (Maybe Class)
selectClassById = Q.statement sql evText (D.maybeRow classRow) True
  where
    sql = selectClassSql <> " WHERE id = $1 :: uuid"

classRow :: D.Row Class
classRow = Class
    <$> dvUUID
    <*> dvText
    <*> D.nullableValue D.text
    <*> dvUUID
    <*> dvUUID
    <*> dArray D.text

insertClassMembers :: Query (SchoolId, ClassId, [SubjectId]) ()
insertClassMembers = Q.statement sql encode D.unit True
  where
    sql = "INSERT INTO student_class (school_id, class_id, student_id) \
          \ SELECT $1 :: uuid, $2 :: uuid, studentId FROM unnest ($3 :: uuid[]) as studentId \
          \ ON CONFLICT DO NOTHING"
    encode = contramap (\(sid, _, _) -> sid) evText
        <> contramap (\(_, cid, _) -> cid) evText
        <> contramap (\(_, _, sids) -> sids) (eArray E.text)

deleteClassMembers :: Query (SchoolId, ClassId, [SubjectId]) ()
deleteClassMembers = Q.statement sql encode D.unit True
  where
    sql = "DELETE FROM student_class \
          \ WHERE class_id=$2 :: uuid \
          \ AND school_id=$1 :: uuid \
          \ AND student_id IN (SELECT studentId FROM unnest ($3 :: uuid[]) as studentId)"
    encode = contramap (\(sid, _, _) -> sid) evText
        <> contramap (\(_, cid, _) -> cid) evText
        <> contramap (\(_, _, sids) -> sids) (eArray E.text)



insertClass :: Query Class ()
insertClass = Q.statement sql encode D.unit True
  where
    sql = "INSERT INTO class (id, name, description, school_id, created_by) values ($1 :: uuid, $2, $3, $4 :: uuid, $5 :: uuid)"
    encode = contramap (id :: Class -> ClassId) evText
        <> contramap (name :: Class -> Text) evText
        <> contramap (description :: Class -> Maybe Text) (E.nullableValue E.text)
        <> contramap (schoolId :: Class -> SchoolId) evText
        <> contramap (createdBy :: Class -> SubjectId) evText

deleteClassById :: Query (ClassId, SchoolId) Int64
deleteClassById = Q.statement sql eTextPair D.rowsAffected True
  where
    sql = "DELETE FROM class WHERE id = $1 :: uuid AND school_id = $2 :: uuid"



-- Trails

selectTrailsBySchoolId :: Query SchoolId [StoryTrail]
selectTrailsBySchoolId = Q.statement sql evText (D.rowsList trailRow) True
  where
    sql = "SELECT id, name, school_id, stories FROM trail WHERE school_id = $1"

trailRow :: D.Row StoryTrail
trailRow = StoryTrail
    <$> dvUUID
    <*> dvText
    <*> dvUUID
    <*> (map fromIntegral <$> dArray D.int4)

insertTrail :: Query StoryTrail ()
insertTrail = Q.statement sql encode D.unit True
  where
    sql = "INSERT INTO trail (id, name, school_id, stories) \
              \ VALUES ($1, $2, $3, $4)"
    encode = contramap (id :: StoryTrail -> TrailId) evText
        <> contramap (name :: StoryTrail -> Text) evText
        <> contramap (schoolId :: StoryTrail -> Text) evText
        <> contramap (map fromIntegral <$> (stories :: StoryTrail -> [StoryId])) (eArray E.int4)

deleteTrailById :: Query TrailId Int64
deleteTrailById = Q.statement sql evText D.rowsAffected True
  where
    sql = "DELETE FROM trail WHERE id = $1 :: uuid"


-- Word dictionary

selectDictionary :: Query () [(Text, WordDefinition)]
selectDictionary = Q.statement sql mempty decode True
  where
    sql = "SELECT word, index, definition, uses_words FROM dict ORDER BY word, index"
    decode = D.rowsList $ do
        word_ <- dvText
        _ <- D.value D.int2
        defn <- dvText
        uses <- dArray dictEntryTupleValue
        return (word_, (defn, uses))

selectWord :: Query Text [WordDefinition]
selectWord = Q.statement sql evText decode True
  where
    sql = "SELECT index, definition, uses_words \
          \ FROM dict \
          \ WHERE word = $1 \
          \ ORDER BY index"
    decode = D.rowsList $ D.value D.int2 >> (,) <$> dvText <*> dArray dictEntryTupleValue

insertWordDefinition :: Query (Text, WordDefinition) ()
insertWordDefinition = Q.statement sql encoder D.unit True
  where
    sql = "INSERT INTO dict (word, index, definition, uses_words) \
          \ VALUES ($1, \
              \ (SELECT coalesce(max(index)+1, 0) FROM dict WHERE word = $1), \
              \ $2, \
              \ array(SELECT word::dict_entry FROM unnest ($3, $4) AS word))"
    encoder = contramap fst evText
        <> contramap (fst . snd) evText
        <> contramap (map fst . snd . snd) (eArray E.text)
        <> contramap (map (fromIntegral . snd) . snd . snd) (eArray E.int2)

-- Answers

selectAnswersSql :: ByteString
selectAnswersSql = "SELECT story_id, student_id, connect, question, summarise, clarify FROM story_answer"

selectAnswersBySchool :: Query SchoolId [Answer]
selectAnswersBySchool = Q.statement sql evText (D.rowsList answerRow) True
  where
    sql = selectAnswersSql <> " WHERE school_id = $1 :: uuid"

selectAnswersByStudent :: Query (SubjectId, SchoolId) [Answer]
selectAnswersByStudent = Q.statement sql eTextPair (D.rowsList answerRow) True
  where
    sql = selectAnswersSql <> " WHERE student_id = $1 :: uuid AND school_id = $2 :: uuid ORDER BY created_at DESC"

selectAnswersByStory :: Query (SchoolId, StoryId) [Answer]
selectAnswersByStory = Q.statement sql encode (D.rowsList answerRow) True
  where
    encode = contramap fst evText
        <> contramap (fromIntegral . snd) (E.value E.int4)
    sql = selectAnswersSql <> " WHERE school_id = $1 :: uuid AND story_id = $2 ORDER BY created_at DESC"

answerRow :: D.Row Answer
answerRow = Answer
    <$> (fromIntegral <$> D.value D.int4)
    <*> dvUUID
    <*> dvText
    <*> dvText
    <*> dvText
    <*> dvText

insertAnswer :: Query (Answer, SchoolId) ()
insertAnswer = Q.statement sql encode D.unit True
  where
    sql = "INSERT INTO story_answer (story_id, student_id, school_id, connect, question, summarise, clarify) \
          \ VALUES ($1, $2 :: uuid, $3 :: uuid, $4, $5, $6, $7)"
    encode = contramap (fromIntegral . (storyId :: Answer -> Int) . fst) (E.value E.int4)
        <> contramap ((studentId :: Answer -> Text) . fst) evText
        <> contramap snd evText
        <> contramap (connect . fst) evText
        <> contramap (question . fst) evText
        <> contramap (summarise . fst) evText
        <> contramap (clarify . fst) evText

-- Leaderboard

selectLeaderboardBySchoolId :: Query SchoolId [LeaderBoardEntry]
selectLeaderboardBySchoolId = Q.statement sql evText (D.rowsList decode) True
  where
    sql = "SELECT position, name, student_id, score FROM leaderboard WHERE school_id=$1 :: uuid"
    decode = LeaderBoardEntry
        <$> (fromIntegral <$> D.value D.int4)
        <*> dvText
        <*> dvUUID
        <*> (fromIntegral <$> D.value D.int4)

-- Account settings
updateAccountSettings_ :: Query (SubjectId, JSON.Value) ()
updateAccountSettings_ = Q.statement sql encode D.unit True
  where
    sql = "UPDATE login SET settings=$2 where id = $1 :: uuid"
    encode = contramap fst evText
        <> contramap snd (E.value E.jsonb)
