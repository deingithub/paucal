ALTER TABLE systems ADD COLUMN
  current_fronter_pk_id TEXT REFERENCES members(pk_member_id);

ALTER TABLE systems ADD COLUMN
  autoproxy_enable BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE systems ADD COLUMN
  autoproxy_member TEXT REFERENCES members(pk_member_id);

ALTER TABLE systems ADD COLUMN
  autoproxy_latch BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE systems ADD COLUMN
  latch TEXT;

ALTER TABLE members ADD COLUMN
  local_tags TEXT;

ALTER TABLE members ADD COLUMN
  disabled BOOLEAN NOT NULL DEFAULT false;
