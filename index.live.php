<?php

// Load cPanel environment
require_once "/usr/local/cpanel/php/cpanel.php";

// Initialize cPanel API
$cpanel = new CPANEL();

// Fetch the user and home directory information
$username = getenv('REMOTE_USER');
if (!$username) {
    echo "<p>Error: Cannot determine username from environment</p>";
    exit;
}

// Determine the user's real home directory path
$user_info = posix_getpwnam($username);
$home_dir = $user_info['dir'];

if (!file_exists($home_dir)) {
    echo "<p>Error: Cannot determine home directory for user $username</p>";
    exit;
}

echo $cpanel->header('Inode Usage');

?>

<p>The Inode Usage tool provides an overview of inode consumption in your account. It displays total inodes used, breaks down usage by directory, and <strong>allows you to expand directories for detailed inode counts</strong>. Additionally, on this page you can see your cPanel account inode limit and directly access File Manager for quick navigation, helping you manage your quota effectively.</p>
<div class="alert alert-info">
    <span class="glyphicon glyphicon-info-sign"></span>
    <div class="alert-message">
	This table is <strong>updated in real-time</strong> with every page reload. Please note that if you have <i>more than 500,000 inodes</i>, the counting process<strong> can take up to 1 minute</strong>.
    </div>
</div>
<!-- Preloader Section -->
<div id="preloader" style="text-align: center; padding: 20px;">
    <br><br><br>
    <img src="preloader.gif" alt="Loading..." style="width: 50px; height: 50px;" />
    <p style="padding-top: 50px;">Please wait, it can take a few minutes to count all the inodes.</p>
</div>

<div id="inode_table_container" style="display: none;">
    <!-- Inode data table will be populated here -->
</div>

<script>
document.addEventListener('DOMContentLoaded', function () {
    var preloader = document.getElementById('preloader');
    var dataContainer = document.getElementById('inode_table_container');
    var homeDir = "<?php echo addslashes($home_dir); ?>";
    var cp_security_token = "<?php echo $_ENV['cp_security_token']; ?>";
    var server_name = "<?php echo getenv('HTTP_HOST'); ?>";

    function encodePathForClass(path) {
        return path.replace(/[^a-zA-Z0-9]/g, function (c) {
            return '_' + c.charCodeAt(0).toString(16);
        });
    }

    function fetchSubfolders(path) {
        return fetch('fetch_subfolders.live.php?subfolder=' + encodeURIComponent(path))
            .then(response => {
                if (!response.ok) {
                    throw new Error('Network response was not ok');
                }
                return response.json();
            });
    }

    function collapseSubfolders(encodedPath) {
        document.querySelectorAll('.subfolder-of-' + encodedPath).forEach(subRow => {
            const subPath = subRow.dataset.path;
            const subEncodedPath = encodePathForClass(subPath);
            subRow.remove();
            collapseSubfolders(subEncodedPath); // Recursively collapse subfolders
        });
    }

    function toggleSubfolders(row, path, depth) {
        var encodedPath = encodePathForClass(path);
        var icon = row.querySelector('.toggle-icon');
        if (row.classList.contains('expanded')) {
            row.classList.remove('expanded');
            icon.classList.remove('fa-chevron-down');
            icon.classList.add('fa-chevron-right');
            collapseSubfolders(encodedPath);
        } else {
            row.classList.add('expanded');
            icon.classList.remove('fa-chevron-right');
            icon.classList.add('fa-chevron-down');
            fetchSubfolders(path).then(subfolders => {
                // Sort the subfolders by inode count in descending order
                subfolders.sort((a, b) => b.inodes - a.inodes);
                subfolders.forEach(subfolder => {
                    var subRow = document.createElement('tr');
                    subRow.classList.add('folder-row');
                    subRow.classList.add('subfolder-of-' + encodedPath);
                    subRow.dataset.path = subfolder.path;
                    subRow.dataset.depth = depth + 1;
                    var iconHtml = subfolder.has_subfolders ? '<i class="fa fa-chevron-right toggle-icon" style="cursor: pointer; margin-right: 5px;"></i>' : '';
                    var paddingLeft = 20 + (subRow.dataset.depth * 20);
                    subRow.innerHTML = '<td style="padding-left: ' + paddingLeft + 'px;">' + iconHtml + '<a href="#" class="folder-link" data-path="' + subfolder.path + '" style="color: #428bca;">' + subfolder.path + '</a></td><td>' + subfolder.inodes + '</td>';
                    row.parentNode.insertBefore(subRow, row.nextSibling);
                    if (subfolder.has_subfolders) {
                        subRow.querySelector('.toggle-icon').addEventListener('click', function (event) {
                            event.stopPropagation(); // Prevent the event from bubbling up
                            toggleSubfolders(subRow, subfolder.path, depth + 1);
                        });
                    }
                    subRow.querySelector('.folder-link').addEventListener('click', function (event) {
                        event.preventDefault();
                        var folderPath = this.dataset.path.replace(homeDir, '');
                        var fileManagerUrl = `https://${server_name}:2083${cp_security_token}/frontend/jupiter/filemanager/index.html?dirselect=homedir&dir=${encodeURIComponent(folderPath)}`;
                        window.open(fileManagerUrl, '_blank');
                    });
                });
            }).catch(error => {
                console.error('Error fetching subfolders:', error);
                alert('Error fetching subfolders: ' + error.message);
            });
        }
    }

    function fetchInodeData() {
        fetch('fetch_inode_data.live.php')
            .then(function(response) {
                return response.json();
            })
            .then(function(data) {
                // Hide preloader
                preloader.style.display = 'none';

                // Show and populate data container
                dataContainer.style.display = 'block';
                var output = '';

                if (data && data.directories && data.directories.length > 0) {
                    output += '<table class="table table-hover table-bordered" style="width: 100%; border-collapse: collapse; margin-top: 20px;"><thead><tr><th>Directory</th><th>Inodes</th></tr></thead><tbody>';
                    data.directories.forEach(function (dir) {
                        var iconHtml = dir.has_subfolders ? '<i class="fa fa-chevron-right toggle-icon" style="cursor: pointer; margin-right: 5px;"></i>' : '';
                        output += '<tr class="folder-row" data-path="' + dir.path + '" data-depth="0"><td style="padding-left: 20px;">' + iconHtml + '<a href="#" class="folder-link" data-path="' + dir.path + '" style="color: #428bca;">' + dir.path + '</a></td><td>' + dir.inodes + '</td></tr>';
                    });
                    var inodeLimitDisplay = data.inode_limit === "Unlimited" ? "Unlimited" : data.inode_limit;
                    output += '<tr><td><strong>Total</strong></td><td><strong>' + data.total_inodes + ' / ' + inodeLimitDisplay + '</strong></td></tr></tbody></table>';
                } else {
                    output += '<p>No data available.</p>';
                }

                dataContainer.innerHTML = output;

                // Reinitialize folder row events after loading data
                initializeFolderRowEvents();
            })
            .catch(function(error) {
                console.error('Error fetching inode data:', error);
                preloader.innerHTML = 'Failed to load data. Please try reloading the page.';
            });
    }

    function initializeFolderRowEvents() {
        document.querySelectorAll('.folder-row').forEach(row => {
            if (row.querySelector('.toggle-icon')) {
                row.querySelector('.toggle-icon').addEventListener('click', function () {
                    toggleSubfolders(row, row.dataset.path, parseInt(row.dataset.depth));
                });
            }
            row.querySelector('.folder-link').addEventListener('click', function (event) {
                event.preventDefault();
                var folderPath = this.dataset.path.replace(homeDir, '');
                var fileManagerUrl = `https://${server_name}:2083${cp_security_token}/frontend/jupiter/filemanager/index.html?dirselect=homedir&dir=${encodeURIComponent(folderPath)}`;
                window.open(fileManagerUrl, '_blank');
            });
        });
    }

    // Start fetching inode data immediately
    fetchInodeData();
});
</script>

<?php
echo $cpanel->footer();
$cpanel->end();
?>
