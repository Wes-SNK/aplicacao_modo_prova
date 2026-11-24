-- Migration 009: normalize numeric precision in question-bank content hashes.
-- PostgreSQL NUMERIC(1) and NUMERIC(1.00) are semantically equal but produce
-- different JSONB textual representations if the scale is not normalized.
CREATE OR REPLACE FUNCTION public._question_bank_hash(
 p_stem text,p_options jsonb,p_correct text,p_explanation text,p_points numeric
) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path='public'
AS $fn$
 SELECT md5(jsonb_build_object(
   'stem',p_stem,
   'options',p_options,
   'answer',p_correct,
   'explanation',p_explanation,
   'points',trim_scale(p_points)
 )::text);
$fn$;
REVOKE ALL ON FUNCTION public._question_bank_hash(text,jsonb,text,text,numeric)
 FROM PUBLIC,anon,authenticated;