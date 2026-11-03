# Running Prometheus 101 for a group

The workshop fits in an hour for 8–12 people, on Zoom or in a room, moving together: nobody starts a chapter until everyone has passed the last one. Two things make that work. Setup happens before the session, and anyone who falls behind catches up with one command instead of the room waiting for them.

## Before the session

Send the pre-work at least two days ahead:

> **Prometheus 101 — before we meet**
>
> Please do this before the session. It takes 10–15 minutes, most of it downloading images.
>
> 1. Create your own **Elastic Serverless** project (Observability). Everyone uses their own project.
> 2. Follow **Before the session** in the README: https://github.com/ericmustin/prometheus-101-elastic#before-the-session
> 3. You're ready when `make setup` ends with its readiness summary all green, and you can log in to Kibana.
>
> If anything is red, reply with the output of `make status` and we'll sort it out before the session.

Open the call ten minutes early for anyone who didn't get there.

## Run of show

| Start | Block | Minutes | Checkpoint |
|---|---|---|---|
| 0:00 | Welcome: where you start, where you finish, the loop | 4 | `make status` all green, Kibana open |
| 0:04 | 01 Scrape yourself | 5 | `make test`: 3 passed |
| 0:09 | 02 Get it into Elastic | 8 | `make test` green; one row in Kibana |
| 0:17 | 03 Scrape the trading app | 12 | `make test` green; two lines per chart |
| 0:29 | 04 Scrape the platform | 7 | `make test` green |
| 0:36 | 05 Scrape the collector | 5 | `make test` green |
| 0:41 | 06 Choose what to send | 7 | `make test` green, a minute after `make apply` |
| 0:48 | 07 Grafana → Elastic | 7 | `make test` green; a Kibana dashboard saved |
| 0:55 | Wrap-up: README's **What you built** | 5 | — |

**Where the time goes.** Measured on a fresh cluster on 1 November 2026, the machine's part of each chapter (applies, waits for data, grading) takes 16–66 seconds, about 4½ minutes in all. Chapter 06's is the longest, because `make test` waits for the drop list to take effect. Everything else is people reading, pasting and running queries, which comes to an estimated 40–45 minutes for one person working alone. That leaves the room 6–11 minutes of slack across the seven chapters, most of it in 01–05. Chapters 06 and 07 are the tight ones, with three queries each. If you reach 0:48 behind, leave chapter 07's dashboard save for afterwards.

## Each chapter, the same way

1. **Say why.** Read the chapter's one sentence under **Why it matters**, then show its map.
2. **Show the steps at a glance.** People who move fast can work from that list and **The whole change** on their own.
3. **Do each step live** on your screen, saying what it's for in a sentence while they type. The step text is written to be read aloud.
4. **Checkpoint.** At `make test`, ask everyone to post ✅ in the chat, or raise a hand.
5. **Don't wait more than a minute for one person.** Ask them to run `make catchup N` for the next chapter, and move on. They're caught up, and they can try the chapter they missed afterwards.
6. **Close with Say it.** That's the sentence to take to a customer.

The **Note ·** blocks are for afterwards, or for the person who asks "what if…?". Open one on screen when a question calls for it, and otherwise leave them closed.

## Unsticking someone

| Symptom | Ask them to run |
|---|---|
| Their edit doesn't pass | `make hint`: what is still different from the solution |
| They want the exact change | `make answer` |
| They're lost, or a chapter behind | `make catchup N`, for the chapter the group is on |
| They don't know where they are | `make status` |

## Where people get stuck

- **YAML indentation.** `make apply` stops at `promtool` and names the line; nothing reaches the cluster. Chapter 03's job and chapter 06's filters are the long pastes.
- **Ports shifted.** If a port was taken during `make setup`, everything moved by +20000. `make check` prints the real URLs.
- **Kibana.** People need to be logged in to their own project before chapter 02, with Discover in ES|QL mode. `make links` opens each query ready to run.
- **"No results found" above a table.** That is Discover's chart for a one-answer (`time=?_tend`) query. The table below it has the answer.
- **Chapter 02 is green in Prometheus but nothing reaches Elastic.** It is usually the `.env` endpoint or the API key's privileges. `make test` names the failure mode.
- **Chapter 06 run too soon.** "Stopped reaching Elastic" needs about a minute after `make apply`.
- **Docker memory.** The cluster needs about 3 GB. Pods stuck `Pending` usually mean Docker Desktop's limit is too low.

## After the session

Point people to:
- the chapter **Note ·** blocks
- [`FIELD-GUIDE.md`](FIELD-GUIDE.md), for questions to ask, objections, and a five-minute demo
- [`SUPERDEMO-MAP.md`](SUPERDEMO-MAP.md), for where each piece lives in superdemo
- the walkthrough videos, for anyone who missed a chapter
