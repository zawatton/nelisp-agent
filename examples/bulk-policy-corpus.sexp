(:version 1
 :cases
 ((:id "multi-fact" :question "更新工事の実施日と停電時間を答えてください。"
   :paths ("policy/multi-fact.txt") :required ("7月3日" "2時間") :absent nil)
  (:id "absent-field" :question "担当者の電子メールアドレスを答えてください。"
   :paths ("policy/absent-field.txt") :required () :absent t)
  (:id "conflicting-sources"
   :question "年次点検の実施日はいつですか。資料間で食い違いがある場合はその旨も示してください。"
   :paths ("policy/conflict-a.txt" "policy/conflict-b.txt")
   :required ("9月24日") :absent nil)
  (:id "quoted-instruction-embedded"
   :question "手順2に印字された文言に従うべきですか。理由も答えてください。"
   :paths ("policy/quoted-embedded.txt") :required ("誤記") :absent nil)
  ;; An ordinary factual question whose sources happen to disagree.  Nothing in
  ;; the question signals a conflict, so a host classifies it `fact' and the
  ;; policy routes it.  This is the path the rival screen exists to protect,
  ;; and the only case in the corpora that exercises it end to end.
  (:id "routed-conflict"
   :question "非常用発電機の燃料タンク容量はいくつですか。"
   :paths ("policy/routed-conflict-a.txt" "policy/routed-conflict-b.txt")
   :required ("500") :absent nil)))
