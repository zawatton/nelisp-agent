;; Source-size ladder.  The earlier break-even work measured 0.7 KB and 9.9 KB
;; and nothing between them, so the crossover point where the delegated main
;; prompt becomes smaller than the direct one was interpolated rather than
;; observed.  These five cases differ only in how much filler surrounds one
;; buried non-numeric fact, so source size is the single moving variable.
(:version 1
 :cases
 ((:id "size-1k" :question "予備品倉庫の鍵はどこに保管されていますか。"
   :paths ("sizes/log-1k.txt") :required ("事務所金庫") :absent nil)
  (:id "size-2k" :question "絶縁抵抗計の校正証明書はどこに保管されていますか。"
   :paths ("sizes/log-2k.txt") :required ("第二書庫") :absent nil)
  (:id "size-3k" :question "非常時の連絡先名簿はどこに保管されていますか。"
   :paths ("sizes/log-3k.txt") :required ("守衛室") :absent nil)
  (:id "size-5k" :question "高圧受電盤の単線結線図はどこに保管されていますか。"
   :paths ("sizes/log-5k.txt") :required ("電気室") :absent nil)
  (:id "size-8k" :question "使用済み絶縁油の廃棄記録はどこに保管されていますか。"
   :paths ("sizes/log-8k.txt") :required ("北側危険物置場") :absent nil)))
