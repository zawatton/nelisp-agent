(task
  :version 1
  :id "hybrid-demo"
  :plan
  (render
    :language ja
    :claims
    ((claim :id "cloud" :text "推論はクラウドで行います。")
     (claim :id "local" :text "結果はローカルで検証します。")))
  :constraints (:allow-new-claims nil :max-chars 100))
