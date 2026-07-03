#!/bin/bash
# Test TranslageGemma batch translation across language pairs.
# Usage: ./test-translategemma.sh <en2zh|zh2en|ja2zh> [batch_size]
#
# Starts a temporary llama-server, sends [SEGMENT] marked batches,
# and verifies 1:1 marker preservation.
set -e

SCENARIO="${1:-en2zh}"
BATCH="${2:-10}"

case "$SCENARIO" in
  en2zh) SRC="en"; TGT="zh";;
  zh2en) SRC="zh"; TGT="en";;
  ja2zh) SRC="ja"; TGT="zh";;
  ko2zh) SRC="ko"; TGT="zh";;
  *) echo "Usage: $0 <en2zh|zh2en|ja2zh|ko2zh> [batch_size]"; exit 1;;
esac

cleanup() { kill %1 2>/dev/null; }
trap cleanup EXIT

PORT=$(python3 -c "
import socket
s = socket.socket()
s.bind(('', 0))
print(s.getsockname()[1])
s.close()
")
echo "=== TranslageGemma test: $SRC → $TGT, batch=$BATCH ==="

llama-server --hf-repo mradermacher/translategemma-4b-it-GGUF:Q4_K_M \
  --no-jinja \
  --chat-template-kwargs "{\"source_lang_code\":\"$SRC\",\"target_lang_code\":\"$TGT\"}" \
  --host 127.0.0.1 --port "$PORT" -t 4 -ngl auto 2>/dev/null &

echo "Waiting for model..."
for i in $(seq 1 60); do
  if curl -s "http://127.0.0.1:$PORT/v1/models" 2>/dev/null | grep -q '"id"'; then echo "Ready"; break; fi
  sleep 2
done

python3 - "$PORT" "$BATCH" "$SRC" "$TGT" << 'PYEOF'
import json, urllib.request, sys

PORT = sys.argv[1]
BATCH = int(sys.argv[2])
SRC = sys.argv[3]
TGT = sys.argv[4]

TGT_LABEL = {"zh": "Simplified Chinese", "en": "English", "ja": "Japanese", "ko": "Korean"}.get(TGT, TGT)

SAMPLES = {
    ("en", "zh"): [
        "People quite often say that",
        "dynamic arrays in C are difficult",
        "and it is in fact true",
        "They are very much annoying",
        "but I would like to show you my approach",
        "So let us create a classical dynamic array",
        "of numbers and see how it works",
        "We need items and capacity tracking",
        "to manage memory properly",
        "Let us push ten elements into it",
        "and verify they are all there",
        "The code works for any type",
        "so we can reuse it easily",
        "I like to wrap this into a macro",
        "called DIY append for convenience",
    ],
    ("zh", "en"): [
        "人们经常说C语言中的动态数组很难用",
        "这确实是事实",
        "它们非常令人困扰",
        "但我想向你展示我的方法",
        "让我们创建一个经典的动态数组",
        "我们需要跟踪元素和容量",
        "以便正确管理内存",
        "让我们向其中推入十个元素",
        "并验证它们是否都在其中",
        "这段代码适用于任何类型",
        "所以我们可以轻松地复用它",
        "我喜欢把它包装成一个宏",
        "叫做DIY append以方便使用",
        "每次需要新的动态数组时",
        "你可以创建不同的类型",
    ],
    ("ko", "zh"): [
        "C 언어의 동적 배열은 어렵다고 자주 말합니다",
        "그리고 그것은 실제로 사실입니다",
        "그것들은 매우 성가신 존재입니다",
        "하지만 제 접근 방식을 보여드리고 싶습니다",
        "고전적인 동적 배열을 만들어 보겠습니다",
        "아이템과 용량을 추적해야 합니다",
        "메모리를 적절히 관리하기 위해서입니다",
        "열 개의 요소를 푸시해 보겠습니다",
        "그리고 그것들이 모두 거기에 있는지 확인합니다",
        "이 코드는 모든 타입에서 작동합니다",
        "그래서 쉽게 재사용할 수 있습니다",
        "저는 이것을 매크로로 감싸는 것을 좋아합니다",
        "DIY append라고 부릅니다",
        "새로운 동적 배열이 필요할 때마다",
        "다른 타입을 만들 수 있습니다",
    ],
    ("ja", "zh"): [
        "C言語の動的配列は難しいとよく言われます",
        "そしてそれは実際にその通りです",
        "それらは非常に厄介です",
        "しかし私のアプローチをお見せしたいと思います",
        "古典的な動的配列を作成しましょう",
        "アイテムとキャパシティを追跡する必要があります",
        "メモリを適切に管理するためです",
        "10個の要素をプッシュしてみましょう",
        "そしてそれらがすべてそこにあることを確認します",
        "このコードは任意の型で動作します",
        "そのため簡単に再利用できます",
        "私はこれをマクロにまとめるのが好きです",
        "DIY appendと呼んでいます",
        "新しい動的配列が必要になるたびに",
        "異なる型を作成できます",
    ],
}

segments = SAMPLES.get((SRC, TGT), SAMPLES[("en", "zh")])[:BATCH]
text = "\n".join(f"[SEGMENT {i+1}]\n{t}\n[/SEGMENT {i+1}]" for i, t in enumerate(segments))

body = json.dumps({
    "messages": [
        {"role": "system", "content": f"Translate each [SEGMENT N] block to {TGT_LABEL}. Keep markers exactly as-is. 1:1 output only."},
        {"role": "user", "content": text}
    ]
}).encode()

req = urllib.request.Request(
    f"http://127.0.0.1:{PORT}/v1/chat/completions",
    data=body,
    headers={"Content-Type": "application/json"}
)
resp = json.loads(urllib.request.urlopen(req, timeout=120).read())
content = resp["choices"][0]["message"]["content"]
count = content.count("[SEGMENT ")
status = "PASS" if count >= BATCH else "FAIL"
print(f"[{status}] Segments: {count}/{BATCH}")
print(content[:600])
PYEOF

echo ""
echo "Done: $SCENARIO"
