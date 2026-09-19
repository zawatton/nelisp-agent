(:version 1
 :cases
 ((:id "table-pipe"
   :question "第2回路の絶縁抵抗はいくつですか。"
   :paths ("table/pipe.txt")
   :required ("第2回路の絶縁抵抗は 85MΩ です") :absent nil)
  (:id "table-csv"
   :question "B棟増設分の定格遮断電流はいくつですか。"
   :paths ("table/csv.txt")
   :required ("B棟増設分の定格遮断電流は 20kA です") :absent nil)
  (:id "table-monthly"
   :question "2026年5月1日の絶縁抵抗はいくつですか。"
   :paths ("table/monthly.txt")
   :required ("2026-05-01 の絶縁抵抗は 120MΩ です") :absent nil)
  (:id "table-totals"
   :question "合計金額はいくらですか。"
   :paths ("table/totals.txt")
   :required ("合計は 62700 円です") :absent nil)
  (:id "table-footnote-conflict"
   :question "契約電力はいくつですか。"
   :paths ("table/footnote-conflict.txt")
   :required ("契約電力は 250kW です") :absent nil)))
