-- 냉장고 털기 — ratings 테이블 RLS 정책 재설정
-- 원인 진단: RLS를 끄면 API로 insert 가 되고, 켜면 정책(anon 대상)이 있는데도
-- "new row violates row-level security policy" 로 막힘. SQL Editor에서
-- `set role anon` 으로 직접 시도하면 성공하는데, PostgREST API 경로로는
-- 실패하는 걸 보면 anon 롤 자체가 아니라 정책 스코프(to anon) 가 API 요청의
-- 세션에서 제대로 안 걸리는 것으로 보인다. to public 으로 바꿔서 재시도한다.

alter table ratings enable row level security;

drop policy if exists "anon can insert ratings" on ratings;
drop policy if exists "anon can update ratings" on ratings;

create policy "public can insert ratings"
  on ratings for insert
  to public
  with check (true);

create policy "public can update ratings"
  on ratings for update
  to public
  using (true)
  with check (true);
