{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}

module Blog.App
(
  app
)
where

import Blog.User
import Blog.Post
import Blog.Comment
import Blog.Assets
import Blog.AppState
import Blog.Page
import Blog.Util.Markdown
import qualified Blog.CSS as CSS
import qualified Blog.SVG as SVG

import Web.App
import Network.HTTP.Types.Status
import Network.HTTP.Types.URI

import Data.Maybe
import Data.Bool
import Data.Niagra (css')
 
import Control.Monad
import Control.Monad.IO.Class

import qualified Crypto.BCrypt as BCrypt

import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.ByteString.Char8 as B

-- TODO
-- 1. Fix pagination and drafts
-- 2. Comment-optional posts - requires an additional column on post_t
-- 3. Editor key commands (cmd-i, cmd-b, etc) - this is all javascript
-- 4. search - title, body, and tags - requires changes to Postgres indeces
-- 5. 'Top 5' tags map in side bar - requires another postgres view
-- 6. JSON API - requires additions to webapp to parse JSON bodies

--------------------------------------------------------------------------------

app :: [Route AppState IO]
app = [
  get      "/"                                 $ getPostsPage False,
  get      "/drafts"                           $ getPostsPage True,
  get      "/login"                            getLogin,
  post     "/login"                            postLogin,
  get      "/logout"                           $ deleteAuth >> redirect "/",
  post     "/posts"                            postPosts,
  delete   "/posts"                            deletePosts,
  get      "/posts/new"                        $ authenticate >> getPostEditor True,
  get      "/posts/:id"                        getPagePostById,
  get      "/posts/by/tag/:tag"                $ getPostsPage False,
  get      "/posts/:id/edit"                   $ getPostEditor False,
  post     "/posts/:id/comments"               postComments,
  get      "/assets/css/blog.css"              $ cssFile CSS.blog,
  get      "/assets/css/comments.css"          $ cssFile CSS.comments,
  get      "/assets/css/editor.css"            $ cssFile CSS.editor,
  get      "/assets/css/wordlist.css"          $ cssFile CSS.wordlist,
  get      "/assets/images/gobutton.svg"       $ svgFile SVG.goButton,
  get      "/assets/images/philly_skyline.svg" $ svgFile SVG.phillySkyline,
  get      (regex "/assets/(.*)")              $ param "1" >>= loadAsset,
  matchAll                                     $ errorPage "Not Found" "The page you are looking for does not exist."
  ]
  
keywords :: [T.Text]
keywords = ["nate", "nathaniel", "symer", "computer", "science", "software",
            "functional", "programming", "web", "haskell", "ruby", "python",
            "linux", "swift", "ios", "mac", "firmware", "iot", "internet", "things"]
            
copyright :: T.Text
copyright = "© 2017, Nathaniel Symer"

defaultDescription :: T.Text
defaultDescription = "Nate Symer software engineer website and blog."

{- Route functions -}

getPostsPage :: (MonadIO m) => Bool -> RouteT AppState m ()
getPostsPage isdrafts = do
  pageNum <- pageNumber
  if isdrafts
    then do
      u <- authenticate
      getter <- maybe (getDrafts u) (getDraftsByTag u) <$> maybeParam "tag"
      f pageNum =<< (getter pageNum)
    else do
      getter <- maybe getPosts getPostsByTag <$> maybeParam "tag"
      f pageNum =<< getter pageNum
  where f pageNum posts = page pghead (top ++ bottom)
          where
            pghead = Head (fromMaybe "Nate Symer" pgtitle) desc keywords False []
            pgtitle = bool Nothing (Just "Drafts") isdrafts
            top = ((Header False pgtitle):(map (PostRepr True) posts))
            bottom = [
              PageControls (length posts > postsPerPage) pageNum,
              Footer copyright]
            desc = bool defaultDescription mempty isdrafts

getPagePostById :: (MonadIO m) => RouteT AppState m ()
getPagePostById = param "id" >>= getPost >>= maybe (redirect "/notfound") f
  where
    f pst@(Post pid ptitle bdy _ ptags draft author) = void $ do
      when draft $ do
        maybeUser <- getAuthenticatedUser
        when (maybe True (/= author) maybeUser) $ redirect "/notfound"
      comments <- getCommentsForPost pid
      let desc = T.take 500 $ stripMarkdown $ parseMarkdown bdy
      page (Head ptitle desc (keywords ++ ptags) False [css' CSS.comments]) ([
        Header False Nothing,
        PostRepr False pst,
        CommentEditor pid Nothing
        ] ++ map (CommentRepr 0) comments ++ [Footer copyright])

getPostEditor :: (MonadIO m) => Bool -> RouteT AppState m ()
getPostEditor allowEmpty = authenticate >> (param "id" >>= getPost >>= m)
  where m = bool (maybe next (f . Just)) f allowEmpty
        f pst = page (Head pgTitle "" [] True csses) [Header True (Just pgTitle), Editor pst]
          where pgTitle = maybe "New Post" postTitle pst
                csses = [css' CSS.editor, css' CSS.wordlist]

getLogin :: (MonadIO m) => RouteT AppState m ()
getLogin = do
  maybeUser <- getAuthenticatedUser
  when (isJust maybeUser) $ redirect "/"
  login <- Login <$> maybeParam "err" <*> maybeParam "username"
  page (Head "Login" "" [] True []) [Header True (Just "Login"), login]

errorPage :: (MonadIO m) => T.Text -> T.Text -> RouteT AppState m ()
errorPage t msg = page (Head t mempty [] True []) [Header False Nothing, Error msg]

postLogin :: (MonadIO m) => RouteT AppState m ()
postLogin = param "username" >>= getUser >>= f
  where
    f Nothing = redirectLogin [("err", Just "Username does not exist.")]
    f (Just user@(User _ _ phash)) = do
      pPassword <- param "password"
      if BCrypt.validatePassword (T.encodeUtf8 phash) pPassword
        then setAuthenticatedUser user >> redirect "/"
        else redirectLogin [("err", Just "Invalid password.")]
    redirectLogin q = do
      mu <- maybeParam "username"
      redirect $ mappend "/login" $ renderQuery True (("username", mu):q)

postPosts :: (MonadIO m) => RouteT AppState m ()
postPosts = handleMethod =<< (fromMaybe "POST" <$> maybeParam "method")
  where
    handleMethod :: (MonadIO m) => B.ByteString -> RouteT AppState m ()
    handleMethod "DELETE" = deletePosts
    handleMethod _ = do
      p <- join $ upsertPost
                    <$> maybeParam "id"
                    <*> (fmap (T.decodeUtf8 . uncrlf) <$> maybeParam "title")
                    <*> (fmap (T.decodeUtf8 . uncrlf) <$> maybeParam "body")
                    <*> (fmap (T.splitOn ",")         <$> maybeParam "tags")
                    <*> (fmap not                     <$> maybeParam "draft")
                    <*> authenticate
      maybe (status status400) (redirect . B.pack . (++) "/posts/" . show) p
      where uncrlf = B.foldl f mempty
              where f bs c
                      | c == '\n' && B.last bs == '\r' = B.snoc (B.init bs) '\n'
                      | otherwise = B.snoc bs c
                      
deletePosts :: (MonadIO m) => RouteT AppState m ()
deletePosts = maybe (status status404) (const $ redirect "/") =<< del
  where del = join $ deletePost <$> authenticate <*> param "id"
  
postComments :: (MonadIO m) => RouteT AppState m ()
postComments = doInsert >>= maybe (status status500) f
  where
    f c = redirect $ B.pack $ mconcat ["/posts/",
                                       show $ commentPostID c,
                                       "#comment",
                                       show $ commentID c]
    doInsert = join $ insertComment
                      <$> maybeParam "parent_id"
                      <*> param "id"
                      <*> param "body"
  
{- Helper Functions -}

pageNumber :: (WebAppState s, MonadIO m) => RouteT s m Integer
pageNumber = fromMaybe 0 <$> maybeParam "page"