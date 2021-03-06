{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}

module Blog.App
(
  app
)
where

import Blog.User
import Blog.Post
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
-- 1. search - title, body, and tags - requires changes to Postgres indeces
--   - below the search field, top 5 tags
-- 2. Integration with a feed system like RSS

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
  get      "/assets/css/blog.css"              $ cssFile CSS.blog,
  get      "/assets/css/editor.css"            $ cssFile CSS.editor,
  get      "/assets/css/wordlist.css"          $ cssFile CSS.wordlist,
  get      "/assets/images/gobutton.svg"       $ svgFile SVG.goButton,
  get      "/assets/images/philly_skyline.svg" $ svgFile SVG.phillySkyline,
  get      (regex "/assets/(.*)")              $ param "1" >>= loadAsset,
  matchAll                                     $ errorPage "Not Found" "The page you are looking for does not exist."
  ]
  
keywords :: [T.Text]
keywords = ["nate", "nathaniel", "symer", "computer", "science", "software",
            "functional", "programmer", "engineer", "web", "haskell", "ruby", "python",
            "linux", "swift", "ios", "mac", "firmware", "iot", "internet", "things"]
            
copyright :: T.Text
copyright = "© 2017, Nathaniel Symer"

defaultDescription :: T.Text
defaultDescription = "Nate Symer software engineer website and blog."

{- Web App Frontend -}

getPostsPage :: (MonadIO m) => Bool -> RouteT AppState m ()
getPostsPage isdrafts = do
  pageNum <- pageNumber
  if isdrafts
    then do
      u <- authenticate
      getter <- maybe (getDrafts u) (getDraftsByTag u) <$> maybeParam "tag"
      f pageNum =<< getter pageNum
    else (join ((maybe getPosts getPostsByTag <$> maybeParam "tag") <*> pure pageNum)) >>= f pageNum
  where f pageNum posts = page pghead (top ++ bottom)
          where
            pghead = Head (fromMaybe "Nate Symer" pgtitle) desc keywords False []
            pgtitle = bool Nothing (Just "Drafts") isdrafts
            top = (pack $ Header False True pgtitle):(map (pack . PostRepr True) posts)
            bottom = [
              pack $ PageControls (length posts > postsPerPage) pageNum isdrafts,
              pack $ Footer copyright]
            desc = bool defaultDescription mempty isdrafts

getPagePostById :: (MonadIO m) => RouteT AppState m ()
getPagePostById = param "id" >>= getPost >>= maybe (redirect "/notfound") f
  where
    f pst@(Post _ ptitle bdy _ ptags draft author) = void $ do
      when draft $ do
        maybeUser <- getAuthenticatedUser
        when (maybe True (/= author) maybeUser) $ redirect "/notfound"

      let desc = T.take 500 $ stripMarkdown $ parseMarkdown bdy
      page (Head ptitle desc (keywords ++ ptags) False []) ([
        pack $ Header False True Nothing,
        pack $ PostRepr False pst,
        pack $ Footer copyright])

getPostEditor :: (MonadIO m) => Bool -> RouteT AppState m ()
getPostEditor allowEmpty = authenticate >> (maybeParam "id" >>= maybe m getPost >>= n) 
  where m = bool next (pure Nothing) allowEmpty
        n = bool (maybe next (f . Just)) f allowEmpty
        f pst = page (Head pgTitle "" [] True csses) [pack $ Header True False Nothing,
                                                      pack $ Editor pst]
          where pgTitle = maybe "New Post" postTitle pst
                csses = map css' [CSS.editor, CSS.wordlist]

getLogin :: (MonadIO m) => RouteT AppState m ()
getLogin = do
  login <- Login <$> maybeParam "err" <*> maybeParam "username"
  page (Head "Login" "" [] True []) [pack $ Header True False (Just "Login"), pack login]

errorPage :: (MonadIO m) => T.Text -> T.Text -> RouteT AppState m ()
errorPage t msg = page (Head t mempty [] True []) [pack $ Header False True Nothing, pack $ Error msg]

{- Web App Backend -}

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
    publicToDraftBool :: Maybe B.ByteString -> Maybe Bool
    publicToDraftBool = Just . isNothing
    handleMethod :: (MonadIO m) => B.ByteString -> RouteT AppState m ()
    handleMethod "DELETE" = deletePosts
    handleMethod _ = do
      p <- join $ upsertPost
                    <$> maybeParam "id"
                    <*> (fmap (T.decodeUtf8 . B.filter (/= '\r')) <$> maybeParam "title")
                    <*> (fmap (T.decodeUtf8 . B.filter (/= '\r')) <$> maybeParam "body")
                    <*> (fmap (T.splitOn ",")                     <$> maybeParam "tags")
                    <*> (publicToDraftBool                        <$> maybeParam "draft")
                    <*> authenticate
      maybe (status status400) (redirect . B.pack . (++) "/posts/" . show) p
                      
deletePosts :: (MonadIO m) => RouteT AppState m ()
deletePosts = maybe (status status404) (const $ redirect "/") =<< del
  where del = join $ deletePost <$> authenticate <*> param "id"
  
{- Helper Functions -}

pageNumber :: (WebAppState s, MonadIO m) => RouteT s m Integer
pageNumber = fromMaybe 0 <$> maybeParam "page"

