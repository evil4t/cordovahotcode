function checkUpdate() {
    var options = {
        'config-file': 'http://120.79.220.96:3350/hotcode/chcp.json'
    };
    chcp.checkUpdate(checkUpdateCallbackMethod, options);
    say_shadow.style.display = "block";
    load_in.style.display = "block";
    function checkUpdateCallbackMethod(error, data) {
        if (error && error.code === chcp.error.NOTHING_TO_UPDATE) {
            say_shadow.style.display = "none";
            load_in.style.display = "none";
            alert('当前已是最新版本');
        } else if (error) {
            say_shadow.style.display = "none";
            load_in.style.display = "none";
            alert('请求异常 code:'+ error.code);
        } else {
            say_shadow.style.display = "none";
            load_in.style.display = "none";
            var message = "是否更新，版本信息：" + data.config.release;
            var title = "新版本提醒";
            var buttonLabels = "立即更新,暂不更新";
            //console.log('======');
            navigator.notification.confirm(message, confirmCallback, title, buttonLabels);
            
            function confirmCallback(buttonIndex) {
                if (buttonIndex == 1) {
                    say_shadow.style.display = "block";
                    load_in.style.display = "block";
                    load_in_text.innerHTML = "开始下载...";
                    chcp.doUpdate(doUpdateCallbackMethod, data);
                    function doUpdateCallbackMethod(error, data) {
                        if (error) {
                            say_shadow.style.display = "none";
                            load_in.style.display = "none";
                            //alert('更新资源异常 code:'+ error.code);
                            if (error.code == -4) {
                                var message = "下载中断，请检查网络";
                                var title = "更新资源异常";
                                var buttonLabels = "重试,取消";
                            
                                navigator.notification.confirm(message, confirmCallback2, title, buttonLabels);
                                //ios only
                                function confirmCallback2(buttonIndex) {
                                    if (buttonIndex == 1) {
                                        chcp.retryDownload();
                                        say_shadow.style.display = "block";
                                        load_in.style.display = "block";
                                        load_in_text.innerHTML = "正在重试...";
                                    } else {
                                        chcp.cancelDownload();
                                    }
                                }
                            } else {
                                alert('更新资源异常 code:'+ error.code);
                            }
                            
                        } else {
                            if (data.counter) {
                                load_in_text.innerHTML = "开始下载...（" + data.counter.currentfile + "/" + data.counter.totalfiles + ")";
                            } else {
                                load_in_text.innerHTML = "开始下载完成，开始安装更新";
                                chcp.installUpdate(installUpdateCallbackMethod);
                                function installUpdateCallbackMethod(error) {
                                    say_shadow.style.display = "none";
                                    load_in.style.display = "none";
                                    if (error) {
                                        alert('安装资源异常 code:'+ error.code);
                                    } else {
                                        alert('更新完成');
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
}
