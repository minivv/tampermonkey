// ==UserScript==
// @name         国开答题助手（可自动勾选答案、一键复制题目及提示词到剪贴板）
// @namespace    https://github.com/minivv/tampermonkey
// @version      0.5
// @description  国开答题辅助工具，可自动勾选答案、一键复制题目及提示词到剪贴板。
// @author       minivv
// @match        https://lms.ouchn.cn/exam/*/subjects*
// @grant        GM_addStyle
// @grant        GM_setClipboard
// @run-at       document-idle
// ==/UserScript==

(function() {
    'use strict';

    // --- UI 元素 ---
    const panel = document.createElement('div');
    panel.id = 'answerHelperPanel';
    document.body.appendChild(panel);

    const title = document.createElement('h3');
    title.textContent = '国开答题助手';
    panel.appendChild(title);

    const instructions = document.createElement('p');
    instructions.innerHTML = `请粘贴答案，格式如下：<br>1. A<br>2. A, B<br>3. C<br>(题号后可跟 . 或 、 或 ．)`;
    panel.appendChild(instructions);

    const answerTextArea = document.createElement('textarea');
    answerTextArea.id = 'answerInputArea';
    answerTextArea.rows = 8; // 减少一点行数给新按钮空间
    answerTextArea.cols = 35;
    answerTextArea.placeholder = "例如：\n1. A\n2. A, B\n3. C,D\n49. A,B,C";
    panel.appendChild(answerTextArea);

    const submitButton = document.createElement('button');
    submitButton.id = 'submitAnswersButton';
    submitButton.textContent = '自动勾选答案';
    panel.appendChild(submitButton);

    const copyButton = document.createElement('button'); // 新增复制按钮
    copyButton.id = 'copyQuestionsButton';
    copyButton.textContent = '复制题目到剪贴板';
    copyButton.style.marginTop = '8px'; // 和上一个按钮有点间距
    panel.appendChild(copyButton);

    const statusDiv = document.createElement('div');
    statusDiv.id = 'statusMessage';
    panel.appendChild(statusDiv);

    // --- 样式 ---
    GM_addStyle(`
        #answerHelperPanel {
            position: fixed;
            top: 80px;
            right: 20px;
            background-color: #f8f9fa;
            border: 1px solid #ced4da;
            padding: 15px;
            z-index: 10000;
            box-shadow: 0 4px 8px rgba(0,0,0,0.1);
            font-family: "Microsoft YaHei", "Segoe UI", Roboto, sans-serif;
            width: 300px;
            border-radius: 8px;
        }
        #answerHelperPanel h3 {
            margin-top: 0;
            margin-bottom: 10px;
            color: #343a40;
            font-size: 1.2em;
            text-align: center;
        }
        #answerHelperPanel p {
            font-size: 0.85em;
            color: #495057;
            margin-bottom: 10px;
            line-height: 1.4;
        }
        #answerInputArea {
            width: 100%;
            box-sizing: border-box;
            margin-bottom: 10px;
            border: 1px solid #ced4da;
            padding: 8px;
            border-radius: 4px;
            font-size: 0.9em;
        }
        #submitAnswersButton {
            background-color: #007bff;
            color: white;
            padding: 10px 15px;
            border: none;
            cursor: pointer;
            border-radius: 4px;
            width: 100%;
            box-sizing: border-box;
            font-size: 1em;
        }
        #submitAnswersButton:hover, #copyQuestionsButton:hover { /* 应用到两个按钮 */
            background-color: #0056b3;
        }
        #copyQuestionsButton { /* 复制按钮的特定样式 (如果需要额外调整) */
            background-color: #28a745; /* 例如用绿色 */
            color: white;
            padding: 10px 15px;
            border: none;
            cursor: pointer;
            border-radius: 4px;
            width: 100%;
            box-sizing: border-box;
            font-size: 1em;
        }
        #copyQuestionsButton:hover {
            background-color: #1e7e34; /* 绿色悬停 */
        }
        #statusMessage {
            margin-top: 12px;
            font-size: 0.85em;
            padding: 8px;
            border-radius: 4px;
            background-color: #e9ecef;
            min-height: 30px;
            max-height: 150px;
            overflow-y: auto;
        }
    `);

    // --- 选择器配置 (全局) ---
    // 1. `questionBlocksSelector`: 选取【每一个独立题目】的容器元素。
    const questionBlocksSelector = 'div[ng-if="subject.isObjective()"]';

    // 2. `questionNumberSelector`: 在单个题目块(block)内部，找到【题号数字所在的元素】。
    const questionNumberSelector = '.subject-resort-index span.ng-binding';

    // 3. `optionLabelsSelector`: 在单个题目块(block)内部，找到【每个选项的<label>元素】。
    const optionLabelsSelector = 'ol.subject-options li.option > label';

    // 4. `getOptionInputElement`: 根据选项的<label>元素，找到其对应的【可选的<input>元素】。
    function getOptionInputElement(labelElement) {
        return labelElement.querySelector('input[type="radio"], input[type="checkbox"]');
    }

    // 5. `getOptionLetter`: 从选项的<label>元素中提取【选项字母 (A, B, C...)】。
    function getOptionLetter(labelElement) {
        const optionIndexElement = labelElement.querySelector('span.option-index');
        return optionIndexElement ? optionIndexElement.textContent.trim().toUpperCase() : null;
    }

    // 6. `getOptionText`: 从选项的<label>元素中提取【选项的文本内容】。
    function getOptionText(labelElement) {
        const optionContentElement = labelElement.querySelector('.option-content');
        return optionContentElement ? optionContentElement.textContent.trim() : '选项内容为空';
    }

    // 7. `getQuestionStem`: 从题目块(block)中提取【题干/描述】。
    function getQuestionStem(block) {
        const stemElement = block.querySelector('.subject-description'); // 您提供的HTML中题干的class
        return stemElement ? stemElement.textContent.trim() : '题干为空';
    }

    // 8. `getQuestionType`: 从题目块(block)中提取【题目类型】。
    function getQuestionType(block) {
        const typeElement = block.querySelector('.summary-sub-title span.ng-binding:first-child'); // 您提供的HTML中题型的选择器
        return typeElement ? typeElement.textContent.trim() : '类型未知';
    }
    // --- 选择器配置结束 ---

    // --- 核心逻辑 ---
    submitButton.addEventListener('click', processAnswers);
    copyButton.addEventListener('click', copyQuestionsToClipboard); // 新按钮的事件监听

    function logStatus(message, isError = false) {
        const now = new Date();
        const timestamp = `${now.getHours()}:${now.getMinutes().toString().padStart(2, '0')}:${now.getSeconds().toString().padStart(2, '0')}`;
        const newLogEntry = document.createElement('div');
        newLogEntry.textContent = `[${timestamp}] ${message}`;
        newLogEntry.style.color = isError ? '#dc3545' : '#28a745';
        if (isError) newLogEntry.style.fontWeight = 'bold';
        newLogEntry.style.marginBottom = '5px'; // 为每条日志添加下边距

        statusDiv.appendChild(newLogEntry);
        statusDiv.scrollTop = statusDiv.scrollHeight;

        console.log((isError ? "错误: " : "状态: ") + message);
    }

    function parseInput(inputText) {
        const lines = inputText.trim().split('\n');
        const parsed = [];
        const lineRegex = /^(\d+)\s*[．.\u3001]\s*([A-Za-z](?:\s*,\s*[A-Za-z])*)$/;

        for (const line of lines) {
            const trimmedLine = line.trim();
            if (trimmedLine === "") continue;

            const match = trimmedLine.match(lineRegex);
            if (match) {
                const qNum = match[1];
                const answers = match[2].split(',').map(a => a.trim().toUpperCase());
                parsed.push({ qNum, answers });
            } else {
                logStatus(`无法解析行: "${trimmedLine}". 请检查格式 (例如: 1. A 或 1. A,B).`, true);
            }
        }
        return parsed;
    }

    function processAnswers() {
        statusDiv.innerHTML = '';
        logStatus("开始处理...", false);
        const inputText = answerTextArea.value;
        if (!inputText.trim()) {
            logStatus("请输入答案!", true);
            return;
        }

        const userAnswers = parseInput(inputText);
        if (!userAnswers || userAnswers.length === 0) {
            logStatus("未解析到有效答案或输入格式完全错误.", true);
            return;
        }

        logStatus(`解析到 ${userAnswers.length} 条答案. 开始匹配题目...`, false);

        const questionBlocks = document.querySelectorAll(questionBlocksSelector);

        if (questionBlocks.length === 0) {
            logStatus(`错误: 未在页面上找到任何题目块 (使用选择器: "${questionBlocksSelector}"). 请确认此选择器是否正确匹配每个题目外层容器。如果题目不是div或者ng-if的值不同，请修改。`, true);
            return;
        }
        logStatus(`在页面上找到 ${questionBlocks.length} 个题目块 (使用 "${questionBlocksSelector}").`, false);

        let questionsFoundAndAttempted = 0;
        let answersSuccessfullySet = 0;

        userAnswers.forEach(ua => {
            let questionMatchedOnPage = false;
            for (const block of questionBlocks) {
                let pageQNum = null;
                const qNumElement = block.querySelector(questionNumberSelector);

                if (qNumElement) {
                    const numMatch = qNumElement.textContent.trim().match(/^(\d+)/);
                    if (numMatch) {
                        pageQNum = numMatch[1];
                    }
                } else {
                    const blockTextMatch = block.textContent.trim().match(/^(\d+)/);
                    if (blockTextMatch) pageQNum = blockTextMatch[1];
                }


                if (pageQNum === ua.qNum) {
                    questionMatchedOnPage = true;
                    questionsFoundAndAttempted++;
                    logStatus(`找到题目 ${ua.qNum}. 尝试选择答案: ${ua.answers.join(', ')}`, false);

                    const optionLabels = block.querySelectorAll(optionLabelsSelector);
                    if (optionLabels.length === 0) {
                        logStatus(`警告: 题目 ${ua.qNum} 内部未找到选项标签 (使用选择器: "${optionLabelsSelector}"). 请检查 'optionLabelsSelector'.`, true);
                        continue;
                    }

                    let optionsSelectedCount = 0;
                    optionLabels.forEach(label => {
                        const inputElement = getOptionInputElement(label);
                        const optionLetter = getOptionLetter(label);

                        if (inputElement && optionLetter) {
                            if (ua.answers.includes(optionLetter)) {
                                if (!inputElement.checked) {
                                    inputElement.click();
                                    if (inputElement.checked) {
                                       logStatus(`  - 题目 ${ua.qNum}: 已选择选项 ${optionLetter}`, false);
                                       optionsSelectedCount++;
                                    } else {
                                       logStatus(`  - 题目 ${ua.qNum}: 尝试点击选项 ${optionLetter}，但似乎未成功选中。可能需要特殊处理或事件触发。`, true);
                                    }
                                } else {
                                    logStatus(`  - 题目 ${ua.qNum}: 选项 ${optionLetter} 已是选中状态.`, false);
                                    optionsSelectedCount++;
                                }
                            }
                        } else if (!inputElement) {
                             logStatus(`  - 题目 ${ua.qNum}: 选项 ${optionLetter || '未知'} 找不到对应的 input 元素.`, true);
                        } else if (!optionLetter) {
                             logStatus(`  - 题目 ${ua.qNum}: 某个选项无法提取选项字母.`, true);
                        }
                    });

                    if (optionsSelectedCount === ua.answers.length) {
                        answersSuccessfullySet++;
                    } else if (ua.answers.length > 0 && optionsSelectedCount < ua.answers.length) {
                        logStatus(`警告: 题目 ${ua.qNum}: 目标选择 ${ua.answers.length} 个, 实际操作 ${optionsSelectedCount} 个. 请检查页面选项是否完整或答案是否有误.`, true);
                    }
                    break;
                }
            }

            if (!questionMatchedOnPage) {
                logStatus(`警告: 未在页面上找到您输入的题目 ${ua.qNum}. 请检查题号或页面题目范围.`, true);
            }
        });

        if (questionsFoundAndAttempted > 0) {
             logStatus(`处理完成! 共匹配到 ${questionsFoundAndAttempted} 个您输入的题目, 其中 ${answersSuccessfullySet} 个题目的选项已按预期设置. 请仔细核对页面上的选择!`, false);
        } else if (userAnswers.length > 0) {
            logStatus("处理完成, 但未能匹配到您输入的任何题目. 请重点检查脚本中的 'questionBlocksSelector' 配置及页面实际题号.", true);
        } else {
            logStatus("处理完成, 没有有效的用户答案输入.", true);
        }
    }

    // --- 新增：复制题目到剪贴板功能 ---
    async function copyQuestionsToClipboard() {
        statusDiv.innerHTML = ''; // 清空日志
        logStatus("开始复制题目内容...", false);

        const questionBlocks = document.querySelectorAll(questionBlocksSelector);
        logStatus(`查找到 ${questionBlocks.length} 个题目块。 (使用选择器: "${questionBlocksSelector}")`, false);

        if (questionBlocks.length === 0) {
            logStatus(`错误: 未在页面上找到任何题目块 (使用选择器: "${questionBlocksSelector}"). 请检查脚本中的选择器配置。`, true);
            return;
        }

        let allQuestionsText = "";
        let questionsCopiedCount = 0;

        questionBlocks.forEach((block, index) => {
            try {
                logStatus(`正在处理第 ${index + 1} 个题目块...`, false);
                let questionText = `仅输出题号和答案的选项，严格按照格式单选: 1. A 或多选 24. A,B,D这种格式输出，多个题目之间需要换行。以下是所有题：\n`;
                let pageQNum = "未知题号";
                const qNumElement = block.querySelector(questionNumberSelector);
                if (qNumElement) {
                    const numMatch = qNumElement.textContent.trim().match(/^(\d+)/);
                    if (numMatch) pageQNum = numMatch[1];
                }

                const qType = getQuestionType(block);
                const qStem = getQuestionStem(block);

                questionText += `题号: ${pageQNum}. (${qType})\n`;
                questionText += `题干: ${qStem}\n`;
                questionText += "选项:\n";

                const optionLabels = block.querySelectorAll(optionLabelsSelector);
                if (optionLabels.length > 0) {
                    optionLabels.forEach(label => {
                        const optionLetter = getOptionLetter(label);
                        const optionTextContent = getOptionText(label);
                        if (optionLetter) {
                            questionText += `  ${optionLetter}. ${optionTextContent}\n`;
                        }
                    });
                } else {
                    questionText += "  (未找到选项或选项格式无法解析)\n";
                }
                questionText += "--------------------\n\n";
                allQuestionsText += questionText;
                questionsCopiedCount++;
            } catch (err) {
                logStatus(`处理题目 ${index + 1} 时出错: ${err.message}`, true);
                console.error(`处理题目 ${index + 1} 时出错:`, err);
            }
        });

        if (questionsCopiedCount > 0) {
            try {
                await navigator.clipboard.writeText(allQuestionsText);
                logStatus(`成功复制 ${questionsCopiedCount} 道题目的内容到剪贴板!`, false);
            } catch (err) {
                logStatus(`复制到剪贴板失败: ${err.message}. 可能是浏览器限制或权限问题。内容已打印到控制台。`, true);
                console.log("复制失败的题目内容：\n", allQuestionsText); // 备用方案，打印到控制台
                // 尝试使用 GM_setClipboard 作为备选方案
                try {
                    GM_setClipboard(allQuestionsText, 'text');
                    logStatus(`已尝试使用 GM_setClipboard 作为备用方案复制内容。`, false);
                } catch (clipErr) {
                    logStatus(`GM_setClipboard 也失败了: ${clipErr.message}. 请检查浏览器设置或手动复制控制台中的内容。`, true);
                }
            }
        } else {
            logStatus("未找到可复制的题目内容。", true);
        }
    }

    logStatus("【答题助手已加载】点击绿色按钮复制题目和AI提示词，将内容粘贴到通义千问、ChatGPT等AI工具中获取答案，然后点击蓝色按钮将答案粘贴回系统。", false);
})();