# bldc_ble

A new Flutter project.


android (joystick) ---(bt24 ble)--> f103 --(dshot)--> g431 

-------------------------
|                       |
|  m3          m2       |
|                       |
|      FC/ESC           |
|                       |
|  m4          m1       |
|                       |
-------------------------

說明

左搖桿：

上/下：改變 _thrBase（集體油門）。

左/右：原地轉向（m1&m3 vs m2&m4），滿推差 500（沿用你 _yawMax）。

右搖桿：

左/右：m1&m2 vs m3&m4 差速（最大差 500）。

上/下：m1&m4 vs m2&m3 差速（最大差 500）。

四個通道最後合成後逐一 _clamp，確保 0/1/48/2047 規則一致。

要把差速上限改小一點做細膩調整，只要調整 _rollMax/_pitchMax/_yawMax
