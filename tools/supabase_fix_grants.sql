-- 냉장고 털기 — 앞서 만든 ratings 테이블에 anon 역할의 쓰기 권한을 추가한다.
-- (RLS 정책은 이미 잘 만들어져 있었는데, 테이블 자체에 대한 기본 권한
--  GRANT 를 빠뜨려서 "new row violates row-level security policy" 오류가
--  났었다. RLS 정책과 GRANT 는 서로 다른 층이라 둘 다 필요하다.)
-- Supabase 대시보드 → SQL Editor 에 붙여넣고 실행하세요.

grant insert, update on public.ratings to anon;
