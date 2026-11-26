/* =====================================================================
   Horizon 8 이벤트 DB (SQL Server) - 전용 Pool 사용자 접속 현황
   - 특정 Pool에 접속한 사용자별 마지막 접속 시각과 미접속 여부를 조회
   - 테이블 접두사를 쓰는 경우 dbo.event* 이름을 바꾸세요 (예: dbo.VE_event)
   ===================================================================== */

-- ▼▼▼ [입력] 여기만 바꾸세요 ▼▼▼
DECLARE @PoolId         NVARCHAR(256) = N'YOUR-POOL-ID'; -- Pool ID (Console의 ID 열, 표시 이름 아님)
DECLARE @Months         INT           = 3;               -- 미접속 기준 (개월)
DECLARE @TzOffset       INT           = 9;               -- 표시 시간대 (KST = +9)
DECLARE @LookbackMonths INT           = NULL;            -- 조회 범위 (개월). NULL = 전체 기간
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
--     (event_historical에는 DesktopId 컬럼이 없어서 상세 테이블의 'DesktopId' 값으로 Pool을 거름)
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
--     도메인(DOMAIN\, domain.local\ 등)을 떼고 계정명으로 묶음
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
