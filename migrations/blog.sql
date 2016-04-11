CREATE TABLE user_t (
  UserID BIGSERIAL PRIMARY KEY,
  UserName TEXT NOT NULL,
  UserPasswordHash TEXT NOT NULL
);

CREATE INDEX user_t_username ON user_t(UserName);

CREATE TABLE post_t (
  PostID BIGSERIAL PRIMARY KEY,
  PostTitle TEXT NOT NULL,
  PostBody TEXT NOT NULL,
  PostCreatedAt TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  PostIsDraft BOOL DEFAULT TRUE,
  PostAuthorID BIGINT REFERENCES user_t(UserID) NOT NULL
);

CREATE INDEX posts_t_not_drafts ON post_t(PostIsDraft) WHERE PostIsDraft IS FALSE;
CREATE INDEX posts_t_drafts     ON post_t(PostIsDraft) WHERE PostIsDraft IS TRUE;

CREATE TABLE tag_t (
  TagID BIGSERIAL PRIMARY KEY,
  TagValue TEXT NOT NULL UNIQUE
);

CREATE INDEX tag_t_tagvalue ON tag_t USING hash (TagValue);

CREATE TABLE post_tag_t (
  PostTagID BIGSERIAL PRIMARY KEY,
  PostID BIGSERIAL NOT NULL REFERENCES post_t(PostID) ON DELETE CASCADE,
  TagID BIGSERIAL NOT NULL REFERENCES tag_t(TagID) ON DELETE CASCADE
);

CREATE TABLE comment_t (
  CommentID BIGSERIAL PRIMARY KEY,
  CommentParentID BIGINT REFERENCES comment_t(CommentID) ON DELETE CASCADE,
  PostID BIGINT NOT NULL REFERENCES post_t(PostID) ON DELETE CASCADE,
  CommentBody TEXT NOT NULL,
  CommentCreatedAt TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE session_t (
  SessionID BIGSERIAL PRIMARY KEY,
  UserID BIGINT NOT NULL REFERENCES user_t(UserID),
  SessionCreatedAt TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE visit_t (
  VisitID BIGSERIAL PRIMARY KEY,
  VisitDate TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  VisitLanguage TEXT, -- Accept-Language
  VisitForwarded TEXT, -- Forwarded
  VisitReferrer TEXT, -- Referrer
  VisitUserAgent TEXT -- User-Agent
);

create index posts_id on post_t(PostID);
create index tags_id on tag_t(TagID);
create index post_tags_tagid ON post_tag_t(TagID);
create index post_tags_postid ON post_tag_t(PostID);

CREATE VIEW v_weighted_tag AS
  SELECT t.TagID,t.TagValue,count(pt.PostID) as TagCount
  FROM tag_t t
  INNER JOIN post_tag_t pt ON t.TagID=pt.TagID
  GROUP BY t.TagID,t.TagValue
  HAVING count(pt.PostID) > 0;
  
CREATE VIEW v_posts_all AS
  SELECT p.PostID,p.PostTitle,p.PostBody,p.PostCreatedAt,
         (
           SELECT array_agg(t.tagvalue)
           FROM tag_t t
           WHERE EXISTS (
             SELECT *
             FROM post_tag_t pt
             where pt.TagID=t.TagID AND pt.postid=p.PostId
           )
         ) as tags,
         p.PostIsDraft,u.UserID,u.UserName
  FROM post_t p
  INNER JOIN user_t u ON p.PostAuthorID=u.UserID
  ORDER BY p.PostCreatedAt DESC;

CREATE VIEW v_posts AS SELECT * FROM v_posts_all WHERE PostIsDraft IS FALSE;
CREATE VIEW v_drafts AS SELECT * FROM v_posts_all WHERE PostIsDraft IS TRUE;

CREATE FUNCTION add_tag(_postid BIGINT,_tag TEXT) RETURNS void AS $$
DECLARE
  _tagid BIGINT;
BEGIN
  SELECT t.TagID FROM tag_t t WHERE t.TagValue=_tag INTO _tagid;

  IF _tagid IS NULL THEN
    INSERT INTO tag_t (TagValue) VALUES (_tag) RETURNING TagID INTO _tagid;
  END IF;
  
  IF NOT EXISTS (SELECT * FROM post_tag_t pt WHERE pt.PostID=_postid AND pt.TagID=_tagid) THEN
    INSERT INTO post_tag_t (PostId,TagId) VALUES (_postid,_tagid);
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION insert_post(_title TEXT, _body TEXT, _isdraft BOOL, _tags TEXT[], _author_id BIGINT) RETURNS BIGINT AS $$
DECLARE
  _postid BIGINT;
BEGIN
  INSERT INTO post_t (PostTitle,PostBody,PostIsDraft,PostAuthorID)
  VALUES (_title,_body,_isdraft,_author_id)
  RETURNING PostID INTO _postid;
  
  IF _postid IS NOT NULL THEN
    FOR i IN 1 .. array_upper(_tags, 1)
    LOOP
       PERFORM add_tag(_postid,_tags[i]);
    END LOOP;
  END IF;
  
  return _postid;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION update_post(_postid BIGINT, _title TEXT, _body TEXT, _isdraft BOOL, _tags TEXT[], _author_id BIGINT) RETURNS BIGINT AS $$
BEGIN
  UPDATE post_t
  SET PostTitle=_title,
      PostBody=_body,
      PostIsDraft=_isdraft
  WHERE PostAuthorID=_author_id AND PostID=_postid;

  FOR i IN 1 .. array_upper(_tags, 1)
  LOOP
     PERFORM add_tag(_postid,_tags[i]);
  END LOOP;

  return _postid;
END;
$$ LANGUAGE plpgsql;