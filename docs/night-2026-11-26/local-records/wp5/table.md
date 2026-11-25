| Configuration | Reads compared (5 ms or more) | Sum of their best times, ms | Same reads, reference | Reads 10 % faster | Reads 10 % slower | Worst slowdown |
|---|---|---|---|---|---|---|
| none | 125 | 92800 | 92800 | 0 | 0 | - |
| jit_off | 125 | 78726 | 92800 | 41 | 26 | 1.62 a:pulse4all-invest current takes refresh |
| work_mem_16MB | 125 | 88682 | 92800 | 46 | 25 | 1.93 a:pulse4all-subscriptions messages: inbox (50 messages) |
| rpc_1.1 | 125 | 84460 | 92800 | 48 | 15 | 1.50 c:pulse4all-subscriptions funnel 92 days: lost reasons |
| all_three | 125 | 74674 | 92800 | 62 | 17 | 1.44 c:pulse4all-subscriptions calls 92 days: overview by day |
| none_generic | 121 | 99327 | 99327 | 0 | 0 | - |
| all_three_generic | 121 | 94414 | 99327 | 32 | 44 | 3.36 b:pulse4all-subscriptions calls previous month: tag use |
