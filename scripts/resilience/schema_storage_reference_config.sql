-- Configuration only: no Storage objects, owner identities or file contents.
-- Reject a result above 100 instead of silently using a truncated seed.
SELECT id,name,public,file_size_limit,allowed_mime_types
FROM storage.buckets WHERE type='STANDARD' ORDER BY id LIMIT 101;
