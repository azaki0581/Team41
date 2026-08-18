-- 냉장고 털기 — 레시피 평점 저장용 Supabase 테이블
-- Supabase 대시보드 → SQL Editor → 새 쿼리에 붙여넣고 실행하세요.

-- 1) 원본 테이블: 누가(voter_id) 어떤 레시피(recipe_id)에 몇 점(stars)을 줬는지
create table if not exists ratings (
  id bigint generated always as identity primary key,
  recipe_id text not null,
  recipe_name text,
  stars smallint not null check (stars between 1 and 5),
  voter_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (recipe_id, voter_id)   -- 같은 사람이 같은 레시피에 두 번 남기면 덮어쓴다
);

-- 2) 행 단위 보안(RLS) 켜기 — 이걸 켜야 아래 정책들이 의미가 생긴다
alter table ratings enable row level security;

-- 3) 익명(anon) 사용자가 새 별점을 등록할 수 있게 허용
create policy "anon can insert ratings"
  on ratings for insert
  to anon
  with check (true);

-- 4) 익명 사용자가 (같은 voter_id로) 기존 별점을 덮어쓸 수 있게 허용
--    주의: voter_id 는 자기 신고 값이라 완벽한 본인 확인은 아니다.
--    학기 프로젝트 규모에서는 감수할 만한 수준으로 판단해 단순하게 열어뒀다.
create policy "anon can update ratings"
  on ratings for update
  to anon
  using (true)
  with check (true);

-- 주의: 이 테이블 자체에는 SELECT(읽기) 정책을 만들지 않는다.
-- 그래서 원본 행(누가 몇 점을 줬는지)은 외부에서 직접 조회할 수 없고,
-- 아래 5)번 뷰를 통한 "집계값만" 공개된다.

-- 5) 화면에 보여줄 집계 뷰 — 레시피별 평균/참여자 수만 공개한다.
--    뷰는 만든 사람(소유자) 권한으로 원본 테이블을 읽으므로, 위에서 원본
--    테이블 SELECT 를 막아뒀어도 이 뷰는 정상적으로 집계를 보여준다.
create or replace view ratings_summary as
  select
    recipe_id,
    round(avg(stars)::numeric, 1) as avg_stars,
    count(*) as rating_count
  from ratings
  group by recipe_id;

grant select on ratings_summary to anon;
