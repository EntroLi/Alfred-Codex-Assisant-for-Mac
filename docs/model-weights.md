# 模型权重与估算边界

核验日期：2026-10-03。当前内部权重版本`2026-10-03-standard`。

来源：官方[ChatGPT Work / Codex Pricing：Token rates](https://learn.chatgpt.com/docs/pricing#token-rates)与[Speed](https://learn.chatgpt.com/docs/agent-configuration/speed)。读取页面全文的相关表格，未用API美元费率替代Codex订阅权重。

| 模型 | 输入/百万token | 缓存输入/百万token | 输出/百万token |
| --- | ---: | ---: | ---: |
| gpt-6-astra | 250 | 25 | 1250 |
| gpt-6.1-sol | 50 | 2.5 | 250 |
| gpt-6-sol | 50 | 5 | 250 |
| gpt-6-luna | 2.5 | 0.25 | 12.5 |
| gpt-5.6-sol | 100 | 10 | 500 |
| gpt-5.6-terra | 50 | 5 | 300 |
| gpt-5.6-luna | 5 | 0.5 | 30 |
| gpt-5.5 | 125 | 12.5 | 750 |

表中数值单位是官方Standard credits，仅内部计算使用。用户界面不展示credits/cr。源码0.7.1的2026-07表保留在Git基线，未核实的旧模型不继续冒称当前已知费率，走未知模型估算。

官方明确credits费率不能直接确定订阅额度消耗；Fast订阅消耗2.5倍、付费credits2倍，Astra Ultrafast分别8倍/6倍，额度可能与其他代理功能共享。本轮没有完整解析各历史任务速度档位、图片/云端/共享消耗，因此周额度比例始终为本机近似，置信度最高显示“低”；不能称账户精确用量分摊。

未知模型依本机已知记录均值（无记录时沿用旧内部兜底权重）作粗略权重，明确标记估算。token仍来自日志，不伪造模型费率。未校准图表显示token，不以credits柱形冒充周额度。

缓存格式保持2，新校准样本追加可选`rateCardVersion`。旧样本留存，但只有同一权重版本用于校准，避免新旧权重混算；升级后可能暂显示“待校准”。历史task/token/标题不因模型费率更新而丢弃。
