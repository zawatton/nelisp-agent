(:version 1
 :cases
 ((:id "dense-insulation"
   :question "第2回路の絶縁抵抗はいくつですか。"
   :paths ("dense/insulation.txt")
   :required ("第2回路の絶縁抵抗は 85MΩ です") :absent nil)
  (:id "dense-ratings"
   :question "遮断器 B-2 の定格電流はいくつですか。"
   :paths ("dense/ratings.txt")
   :required ("遮断器 B-2 の定格電流は 400A です") :absent nil)
  (:id "dense-schedule"
   :question "B事業場の年次点検日はいつですか。"
   :paths ("dense/schedule.txt")
   :required ("B事業場の年次点検日は 9月3日 です") :absent nil)
  (:id "dense-invoice"
   :question "請求合計はいくらですか。"
   :paths ("dense/invoice.txt")
   :required ("請求合計は 62700 円です") :absent nil)
  (:id "dense-buried-conflict"
   :question "契約電力はいくつですか。"
   :paths ("dense/buried-conflict.txt")
   :required ("契約電力は 250kW です") :absent nil)))
