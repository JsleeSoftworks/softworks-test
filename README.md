# Horizon 8 Pool 사용자 접속 현황 조회

Horizon 8 이벤트 데이터베이스(SQL Server)에서 특정 데스크톱 Pool의 사용자별 마지막 접속 시각을 구하고, 일정 기간(기본 3개월) 넘게 접속하지 않은 사용자를 `미접속`으로 표시하는 쿼리입니다.

- 파일: [`horizon_pool_user_activity.sql`](horizon_pool_user_activity.sql)
- 확인 환경: 전용(Dedicated) Pool, SQL Server 2019

## 사용법

1. SSMS에서 Horizon 이벤트 DB를 선택하고 `horizon_pool_user_activity.sql`을 엽니다.
2. 맨 위 `[입력]` 부분만 바꿉니다.

   | 변수 | 설명 | 기본값 |
   |---|---|---|
   | `@PoolId` | Pool ID. Horizon Console의 **ID** 열 값 (표시 이름 아님) | 직접 입력 |
   | `@Months` | 미접속 기준 개월 수 | `3` |
   | `@TzOffset` | 결과 시각에 더할 시간. 한국 시간은 `9` | `9` |
   | `@LookbackMonths` | 조회할 기간(개월). `NULL`이면 전체 기간 | `NULL` |

3. 실행(F5)합니다. 메시지 탭에 단계별 건수와 시각이 표시되어 진행 상황을 볼 수 있습니다.

## 결과 열

| 열 | 내용 |
|---|---|
| 상태 | `미접속` (마지막 접속이 기준일보다 오래됨) / `접속` |
| Pool | 조회한 Pool ID |
| 계정 | 도메인을 뗀 계정명(소문자). `DOMAIN\id`와 `domain.local\id`처럼 표기가 섞여 있어도 한 사람으로 묶음 |
| 최근 표기 | 마지막 접속 때 기록된 원래 사용자 이름 |
| 마지막 접속 머신 | 마지막으로 접속한 머신 이름 |
| 마지막 접속 시각 | `@TzOffset`을 적용한 시각 (`yyyy-mm-dd hh:mi`) |
| 경과 일수 | 마지막 접속 후 지난 날짜 수 |
| 접속 횟수 | 조회 기간 안의 접속 이벤트 수 |

마지막 접속이 오래된 순으로 정렬되어 미접속자가 위에 나옵니다.

## 엑셀로 옮기기

결과 그리드 왼쪽 위 빈칸을 눌러 전체 선택 → 마우스 오른쪽 → **머리글과 함께 복사**(`Ctrl+Shift+C`) → 엑셀에 붙여넣기.

## 사전 확인

Pool ID를 모를 때:

```sql
SELECT DesktopId, COUNT(*) AS Cnt, MAX(Time) AS LastEventUtc
FROM dbo.event
WHERE EventType IN ('AGENT_CONNECTED', 'AGENT_RECONNECTED')
GROUP BY DesktopId
ORDER BY DesktopId;
```

이벤트가 얼마나 오래전 것까지 남아 있는지 (기준 기간보다 이전 기록이 있어야 결과를 믿을 수 있음):

```sql
SELECT (SELECT MIN(Time) FROM dbo.event)            AS Oldest_event,
       (SELECT MIN(Time) FROM dbo.event_historical) AS Oldest_historical;
```

## 동작 방식

- **접속으로 보는 이벤트:** `AGENT_CONNECTED`(새 세션 로그인), `AGENT_RECONNECTED`(재접속).
- **조회 테이블:** 현재 테이블(`event`, `event_data`)과 과거 테이블(`event_historical`, `event_data_historical`)을 모두 읽습니다.
- **과거 테이블의 Pool 구분:** `event_historical`에는 `DesktopId` 컬럼이 없어서, `event_data_historical`의 `Name = 'DesktopId'` 값으로 Pool을 거릅니다.
- **속도:** 가장 큰 `event_data_historical`을 한 번만 읽고 `MAX(CASE ...)`로 사용자·머신·Pool 값을 한꺼번에 뽑습니다. 이 테이블을 여러 번 조인하면 몇 분씩 걸릴 수 있습니다.
- **잠금:** `READ UNCOMMITTED`로 읽어서 Connection Server의 이벤트 기록 작업과 서로 막지 않습니다.

## 주의

- 이벤트 DB에는 실제 접속 기록만 있고 Pool 할당(Entitlement) 정보는 없습니다. 할당만 되고 한 번도 접속하지 않은 사용자는 결과에 나오지 않습니다.
- 퇴사·이동으로 할당이 해제된 사용자도 접속 기록이 남아 있으면 결과에 나옵니다. 현재 할당은 Horizon Console의 Pool → Machines 탭(Assigned User)과 대조하세요.
- 이벤트 정리(cleanup) 설정으로 오래된 이벤트가 지워졌다면 그 이전 접속은 알 수 없습니다.
- 이벤트 시간은 UTC로 저장된다고 보고 계산합니다.
- 이벤트 DB에 테이블 접두사를 설정했다면 `dbo.event*` 이름을 바꿔야 합니다 (예: `dbo.VE_event`).
- SQL Server 문법입니다. PostgreSQL·Oracle 이벤트 DB에서는 수정이 필요합니다.




/* =====================================================================
   Horizon 8 이벤트 DB (SQL Server) - 전용 Pool 사용자 접속 현황
   ===================================================================== */

-- ▼▼▼ [입력] 여기만 바꾸세요 ▼▼▼
DECLARE @PoolId         NVARCHAR(256) = N'199vdi';  -- Pool ID (Console의 ID 열)
DECLARE @Months         INT           = 3;          -- 미접속 기준 (개월)
DECLARE @TzOffset       INT           = 9;          -- 표시 시간대 (KST = +9)
DECLARE @LookbackMonths INT           = NULL;       -- 조회 범위 (개월). NULL = 전체 기간
-- ▲▲▲ [입력] 끝 ▲▲▲

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;   -- 운영 중인 이벤트 DB에 잠금을 걸지 않음

DECLARE @Cutoff DATETIME = DATEADD(MONTH, -@Months, GETUTCDATE());   -- 이벤트 시간은 UTC
DECLARE @From   DATETIME = CASE WHEN @LookbackMonths IS NULL THEN '1900-01-01'
                                ELSE DATEADD(MONTH, -@LookbackMonths, GETUTCDATE()) END;
DECLARE @msg    NVARCHAR(400);

IF OBJECT_ID('tempdb..#Ev')   IS NOT NULL DROP TABLE #Ev;
IF OBJECT_ID('tempdb..#Conn') IS NOT NULL DROP TABLE #Conn;

-- [1] 과거 테이블: 접속 이벤트 ID만 먼저 추리기
SELECT e.EventID, e.Time
INTO #Ev
FROM dbo.event_historical e
WHERE e.EventType IN ('AGENT_CONNECTED', 'AGENT_RECONNECTED')
  AND e.Time >= @From;

SET @msg = CONCAT(N'[1] 과거 접속 이벤트 ', @@ROWCOUNT, N'건  ', CONVERT(VARCHAR(8), GETDATE(), 108));
RAISERROR(@msg, 0, 1) WITH NOWAIT;

CREATE CLUSTERED INDEX IX_Ev ON #Ev (EventID);

-- [2] 과거 상세: event_data_historical을 한 번만 읽어서 Pool/사용자/머신을 한꺼번에 구하기
SELECT h.Time,
       MAX(CASE WHEN d.Name = 'UserDisplayName' THEN d.StrValue END) AS UserName,
       MAX(CASE WHEN d.Name = 'MachineName'     THEN d.StrValue END) AS MachineName
INTO #Conn
FROM #Ev h
JOIN dbo.event_data_historical d ON d.EventID = h.EventID
WHERE d.Name IN ('DesktopId', 'UserDisplayName', 'MachineName')
GROUP BY h.EventID, h.Time
HAVING MAX(CASE WHEN d.Name = 'DesktopId' THEN d.StrValue END) = @PoolId;

SET @msg = CONCAT(N'[2] 과거 중 이 Pool 접속 ', @@ROWCOUNT, N'건  ', CONVERT(VARCHAR(8), GETDATE(), 108));
RAISERROR(@msg, 0, 1) WITH NOWAIT;

-- [3] 현재 테이블 추가
INSERT INTO #Conn (Time, UserName, MachineName)
SELECT e.Time,
       MAX(CASE WHEN d.Name = 'UserDisplayName' THEN d.StrValue END),
       MAX(CASE WHEN d.Name = 'MachineName'     THEN d.StrValue END)
FROM dbo.event e
JOIN dbo.event_data d ON d.EventID = e.EventID
WHERE e.DesktopId = @PoolId
  AND e.EventType IN ('AGENT_CONNECTED', 'AGENT_RECONNECTED')
  AND e.Time >= @From
  AND d.Name IN ('UserDisplayName', 'MachineName')
GROUP BY e.EventID, e.Time;

SET @msg = CONCAT(N'[3] 현재 중 이 Pool 접속 ', @@ROWCOUNT, N'건  ', CONVERT(VARCHAR(8), GETDATE(), 108));
RAISERROR(@msg, 0, 1) WITH NOWAIT;

-- [4] 결과: 사용자별 마지막 접속 + 상태 (미접속자가 위, 오래된 순)
--     도메인(VDI\, vdi.local\ 등)을 떼고 계정명으로 묶음
WITH a AS (
    SELECT UserName, MachineName, Time,
           LOWER(SUBSTRING(UserName, CHARINDEX('\', UserName) + 1, 256)) AS Account
    FROM #Conn
    WHERE UserName IS NOT NULL
),
r AS (
    SELECT Account, UserName, MachineName, Time,
           ROW_NUMBER() OVER (PARTITION BY Account ORDER BY Time DESC) AS rn,
           COUNT(*)     OVER (PARTITION BY Account)                    AS ConnCount
    FROM a
)
SELECT CASE WHEN Time < @Cutoff THEN N'미접속' ELSE N'접속' END        AS [상태],
       @PoolId                                                          AS [Pool],
       Account                                                          AS [계정],
       UserName                                                         AS [최근 표기],
       MachineName                                                      AS [마지막 접속 머신],
       CONVERT(VARCHAR(16), DATEADD(HOUR, @TzOffset, Time), 120)        AS [마지막 접속 시각],
       DATEDIFF(DAY, Time, GETUTCDATE())                                AS [경과 일수],
       ConnCount                                                        AS [접속 횟수]
FROM r
WHERE rn = 1
ORDER BY Time;

DROP TABLE #Ev;
DROP TABLE #Conn;



