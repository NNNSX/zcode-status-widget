!macro customUnInstall
  ${IfNot} ${isUpdated}
    ${If} ${FileExists} "$INSTDIR\${PRODUCT_FILENAME}.exe"
      ExecWait '"$INSTDIR\${PRODUCT_FILENAME}.exe" --unconfigure-hooks --silent' $R0
      ${If} $R0 != 0
        MessageBox MB_ICONSTOP|MB_OK "无法安全移除 ZCode 状态 Hook。卸载已中止，安装目录和 Hook 助手将被保留。"
        Abort
      ${EndIf}
    ${EndIf}
  ${EndIf}
!macroend
